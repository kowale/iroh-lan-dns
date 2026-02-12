use anyhow::Result;
use hickory_proto::op::{Header, Message, ResponseCode};
use hickory_proto::rr::rdata::A;
use hickory_proto::rr::{RData, Record};
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::RwLock;
use tracing::{debug, info};

#[derive(Clone)]
pub struct Dns {
    records: Arc<RwLock<HashMap<String, Ipv4Addr>>>,
}

impl Dns {
    pub fn new() -> Self {
        Self {
            records: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn add(&self, hostname: String, ip: Ipv4Addr) {
        let mut records = self.records.write().await;
        records.insert(hostname.clone(), ip);
        info!("DNS: {} -> {}", hostname, ip);
    }

    pub async fn start(self, port: u16) -> Result<()> {
        let socket = UdpSocket::bind(("127.0.0.1", port)).await?;
        info!("DNS server listening on 127.0.0.1:{}", port);

        let mut buf = vec![0u8; 512];

        loop {
            let (len, addr) = socket.recv_from(&mut buf).await?;
            let query = &buf[..len];

            if let Some(response) = self.handle_query(query).await {
                socket.send_to(&response, addr).await?;
            }
        }
    }

    async fn handle_query(&self, query: &[u8]) -> Option<Vec<u8>> {
        let request = Message::from_vec(query).ok()?;
        let q = request.queries().first()?;
        let name_str = q.name().to_utf8();
        let hostname = name_str.strip_suffix('.').unwrap_or(&name_str);
        debug!("DNS query for: {}", hostname);

        let mut response = Message::new();
        response.set_header({
            let mut header = Header::response_from_request(request.header());
            header.set_recursion_available(true);
            header
        });
        response.add_query(q.clone());

        let records = self.records.read().await;
        if let Some(&ip) = records.get(hostname) {
            let name = q.name().clone();
            let record = Record::from_rdata(name, 60, RData::A(A(ip)));
            response.add_answer(record);
        } else {
            response.set_response_code(ResponseCode::NXDomain);
        }

        response.to_vec().ok()
    }
}
