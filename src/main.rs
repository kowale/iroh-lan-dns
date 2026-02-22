mod dns;

use anyhow::Result;
use clap::Parser;
use iroh_lan::{Network, RouterIp};
use dns::Dns;
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::time::{sleep, Duration};
use tracing::{debug, info, warn};

#[derive(Parser)]
struct Args {
    #[arg(short, long)]
    network: String,

    #[arg(short, long)]
    password: String,

    #[arg(long)]
    hostname: String,

    #[arg(long, default_value = "6666")]
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

    eprintln!("Network: {}", args.network);
    eprintln!("Hostname: {}", args.hostname);
    eprintln!("Joining network...");

    // Join network
    eprintln!("Connecting to iroh-lan network...");
    let network = Network::new(&args.network, &args.password).await?;
    eprintln!("Network joined, waiting for IP...");
    let my_ip = wait_for_ip(&network).await?;
    eprintln!("Got IP: {}", my_ip);

    // Start DNS server
    let dns = Dns::new();
    let full_hostname = format!("{}.internal", args.hostname);
    dns.add(full_hostname.clone(), my_ip).await;

    tokio::spawn({
        let dns = dns.clone();
        async move {
            if let Err(e) = dns.start(args.dns_port).await {
                eprintln!("DNS error: {}", e);
            }
        }
    });

    sleep(Duration::from_millis(100)).await;

    let sock = Arc::new(UdpSocket::bind((my_ip, 53535)).await?);
    info!("Hostname exchange listening on {}:53535", my_ip);

    // Listener: receive peer hostnames
    tokio::spawn({
        let sock = sock.clone();
        let dns = dns.clone();
        async move {
            let mut buf = vec![0u8; 256];
            loop {
                match sock.recv_from(&mut buf).await {
                    Ok((len, src)) => {
                        if let Ok(hostname) = std::str::from_utf8(&buf[..len]) {
                            let peer_ip = match src.ip() {
                                std::net::IpAddr::V4(ip) => ip,
                                _ => continue,
                            };
                            let fqdn = format!("{}.internal", hostname);
                            info!("Peer announced: {} -> {}", fqdn, peer_ip);
                            dns.add(fqdn, peer_ip).await;
                        }
                    }
                    Err(e) => warn!("Hostname exchange recv error: {}", e),
                }
            }
        }
    });

    // Announcer: send our hostname to all peers every 10s
    tokio::spawn({
        let sock = sock.clone();
        let hostname = args.hostname;
        let network = network.clone();
        async move {
            let mut interval = tokio::time::interval(Duration::from_secs(10));
            loop {
                interval.tick().await;
                match network.get_peers().await {
                    Ok(peers) => {
                        for (_, maybe_ip) in &peers {
                            if let Some(peer_ip) = maybe_ip {
                                let dest = std::net::SocketAddr::from((*peer_ip, 53535));
                                if let Err(e) = sock.send_to(hostname.as_bytes(), dest).await {
                                    debug!("Failed to announce to {}: {}", peer_ip, e);
                                }
                            }
                        }
                    }
                    Err(e) => debug!("Failed to get peers: {}", e),
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
