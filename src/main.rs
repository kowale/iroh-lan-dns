use iroh_lan::{RouterIp, Network};
use tokio::time::sleep;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Network name
    #[arg(short, long)]
    name: String,

    /// Network password
    #[arg(short, long)]
    password: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if !self_runas::is_elevated() {
        self_runas::admin()?;
        return Ok(());
    }

    let args = Args::parse();

    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_thread_ids(true)
        .init();

    let network = Network::new(&args.name, &args.password).await?;

    while matches!(
        network.get_router_state().await?,
        RouterIp::NoIp | RouterIp::AquiringIp(_, _)
    ) {
        sleep(std::time::Duration::from_millis(500)).await;
    }

    println!("my ip is {:?}", network.get_router_state().await?);

    tokio::spawn(async move {
        loop {
            println!(
                "Network started with endpoint ID {:?}",
                network.get_router_state().await
            );
            sleep(std::time::Duration::from_secs(5)).await;
        }
    });

    let _ = tokio::signal::ctrl_c().await;
    Ok(())
}
