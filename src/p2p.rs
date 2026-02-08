// Simple P2P hostname announcements
use crate::simple_dns::SimpleDns;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::net::{Ipv4Addr, SocketAddr};
use tokio::net::UdpSocket;
use tokio::time::{interval, Duration};
use tracing::{debug, info, warn};

const P2P_PORT: u16 = 53535;

#[derive(Serialize, Deserialize, Debug)]
struct Announcement {
    hostname: String,
    ip: Ipv4Addr,
}

pub struct P2P {
    socket: UdpSocket,
    my_hostname: String,
    my_ip: Ipv4Addr,
    dns: SimpleDns,
}

impl P2P {
    pub async fn new(hostname: String, ip: Ipv4Addr, dns: SimpleDns) -> Result<Self> {
        let socket = UdpSocket::bind((ip, P2P_PORT)).await?;
        info!("P2P listening on {}:{}", ip, P2P_PORT);

        Ok(Self {
            socket,
            my_hostname: hostname,
            my_ip: ip,
            dns,
        })
    }

    pub async fn run(self, peer_ips: Vec<Ipv4Addr>) {
        let socket = std::sync::Arc::new(self.socket);

        // Listener task
        tokio::spawn({
            let socket = socket.clone();
            let dns = self.dns.clone();
            async move {
                let mut buf = vec![0u8; 1024];
                loop {
                    match socket.recv_from(&mut buf).await {
                        Ok((len, _)) => {
                            if let Ok(ann) = serde_json::from_slice::<Announcement>(&buf[..len]) {
                                info!("Received: {} -> {}", ann.hostname, ann.ip);
                                dns.add(ann.hostname, ann.ip).await;
                            }
                        }
                        Err(e) => warn!("P2P recv error: {}", e),
                    }
                }
            }
        });

        // Announcer task
        tokio::spawn({
            let socket = socket.clone();
            let hostname = self.my_hostname;
            let ip = self.my_ip;

            async move {
                let mut ticker = interval(Duration::from_secs(10));

                loop {
                    ticker.tick().await;

                    let ann = Announcement { hostname: hostname.clone(), ip };
                    if let Ok(bytes) = serde_json::to_vec(&ann) {
                        for peer_ip in &peer_ips {
                            let dest = SocketAddr::from((*peer_ip, P2P_PORT));
                            if let Err(e) = socket.send_to(&bytes, dest).await {
                                debug!("Failed to announce to {}: {}", peer_ip, e);
                            }
                        }
                    }
                }
            }
        });
    }
}
