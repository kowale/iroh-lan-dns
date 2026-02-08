mod p2p;
mod simple_dns;

use anyhow::Result;
use clap::Parser;
use iroh_lan::{Network, RouterIp};
use p2p::P2P;
use simple_dns::SimpleDns;
use std::net::Ipv4Addr;
use tokio::time::{sleep, Duration};
use tracing::info;

#[derive(Parser)]
struct Args {
    #[arg(short, long)]
    name: String,

    #[arg(short, long)]
    password: String,

    #[arg(long)]
    hostname: String,

    #[arg(long, default_value = "5353")]
    dns_port: u16,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .init();

    if !self_runas::is_elevated() {
        eprintln!("Requesting elevated privileges...");
        self_runas::admin()?;
        return Ok(());
    }

    let args = Args::parse();

    eprintln!("=== Tunnels Starting ===");
    eprintln!("Network: {}", args.name);
    eprintln!("Hostname: {}", args.hostname);
    eprintln!("Joining network...");

    // Join network
    eprintln!("Connecting to iroh-lan network...");
    let network = Network::new(&args.name, &args.password).await?;
    eprintln!("Network joined, waiting for IP...");
    let my_ip = wait_for_ip(&network).await?;
    eprintln!("Got VPN IP: {}", my_ip);

    // Start simple DNS server
    let dns = SimpleDns::new();
    let full_hostname = format!("{}.tunnel.internal", args.hostname);
    dns.add(full_hostname.clone(), my_ip).await;

    tokio::spawn({
        let dns = dns.clone();
        async move {
            if let Err(e) = dns.start(args.dns_port).await {
                eprintln!("DNS error: {}", e);
            }
        }
    });

    // Wait a moment for DNS to start
    sleep(Duration::from_millis(100)).await;

    info!("\n=== Ready ===");
    info!("DNS: 127.0.0.1:{}", args.dns_port);
    info!("Test: dig @127.0.0.1 -p {} {}.tunnel.internal", args.dns_port, args.hostname);

    // Start P2P announcements
    let peer_ips = discover_peers(&network).await?;
    if !peer_ips.is_empty() {
        info!("Found {} peers", peer_ips.len());
        let p2p = P2P::new(full_hostname, my_ip, dns).await?;
        p2p.run(peer_ips).await;
    }

    // Status updates
    tokio::spawn({
        let network = network.clone();
        async move {
            let mut interval = tokio::time::interval(Duration::from_secs(30));
            loop {
                interval.tick().await;
                if let Ok(peers) = network.get_peers().await {
                    info!("Connected peers: {}", peers.len());
                }
            }
        }
    });

    tokio::signal::ctrl_c().await?;
    Ok(())
}

async fn wait_for_ip(network: &Network) -> Result<Ipv4Addr> {
    loop {
        match network.get_router_state().await? {
            RouterIp::AssignedIp(ip) => return Ok(ip),
            _ => sleep(Duration::from_millis(500)).await,
        }
    }
}

async fn discover_peers(network: &Network) -> Result<Vec<Ipv4Addr>> {
    let peers = network.get_peers().await?;
    Ok(peers
        .iter()
        .filter_map(|(_, ip)| *ip)
        .collect())
}
