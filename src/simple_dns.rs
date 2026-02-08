// Simple DNS server - just enough to answer A record queries
use anyhow::Result;
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::RwLock;
use tracing::{debug, info};

#[derive(Clone)]
pub struct SimpleDns {
    records: Arc<RwLock<HashMap<String, Ipv4Addr>>>,
}

impl SimpleDns {
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
        // Parse just enough to get the hostname
        let hostname = parse_dns_query(query)?;
        debug!("DNS query for: {}", hostname);

        // Look up the IP
        let records = self.records.read().await;
        let ip = records.get(&hostname)?;

        // Build a simple DNS response
        Some(build_dns_response(query, *ip))
    }
}

// Minimal DNS query parser - just extracts the hostname
fn parse_dns_query(query: &[u8]) -> Option<String> {
    if query.len() < 12 {
        return None;
    }

    // Skip DNS header (12 bytes), parse QNAME
    let mut pos = 12;
    let mut parts = Vec::new();

    while pos < query.len() {
        let len = query[pos] as usize;
        if len == 0 {
            break;
        }
        pos += 1;

        if pos + len > query.len() {
            return None;
        }

        let part = String::from_utf8_lossy(&query[pos..pos + len]).to_string();
        parts.push(part);
        pos += len;
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("."))
    }
}

// Build a simple DNS A record response
fn build_dns_response(query: &[u8], ip: Ipv4Addr) -> Vec<u8> {
    let mut response = Vec::new();

    // Copy query header and modify flags
    response.extend_from_slice(&query[0..2]); // Transaction ID
    response.extend_from_slice(&[0x81, 0x80]); // Flags: response, no error
    response.extend_from_slice(&query[4..6]); // Questions count
    response.extend_from_slice(&[0x00, 0x01]); // Answers count = 1
    response.extend_from_slice(&[0x00, 0x00]); // Authority RRs
    response.extend_from_slice(&[0x00, 0x00]); // Additional RRs

    // Copy the question section
    let question_end = find_question_end(query);
    response.extend_from_slice(&query[12..question_end]);

    // Add answer section
    response.extend_from_slice(&[0xc0, 0x0c]); // Name pointer to question
    response.extend_from_slice(&[0x00, 0x01]); // Type A
    response.extend_from_slice(&[0x00, 0x01]); // Class IN
    response.extend_from_slice(&[0x00, 0x00, 0x00, 0x3c]); // TTL = 60 seconds
    response.extend_from_slice(&[0x00, 0x04]); // Data length = 4
    response.extend_from_slice(&ip.octets()); // IP address

    response
}

fn find_question_end(query: &[u8]) -> usize {
    let mut pos = 12;

    // Skip labels
    while pos < query.len() && query[pos] != 0 {
        pos += query[pos] as usize + 1;
    }

    pos + 1 + 4 // Null byte + type + class
}
