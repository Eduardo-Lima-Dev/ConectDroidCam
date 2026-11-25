use std::net::Ipv4Addr;
use std::thread;

use mdns_sd::{ServiceDaemon, ServiceEvent};
use thiserror::Error;

pub const SERVICE_TYPE: &str = "_conectdroidcam._tcp.local.";

#[derive(Debug, Error)]
pub enum DiscoveryError {
    #[error("não consegui iniciar a descoberta na rede: {0}")]
    Daemon(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub host: String,
    pub addresses: Vec<Ipv4Addr>,
    pub port: u16,
}

impl Device {
    pub fn address(&self) -> Option<String> {
        self.addresses
            .first()
            .map(|ip| format!("{ip}:{}", self.port))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceEvent {
    Found(Device),
    Lost { id: String },
}

pub struct Discovery {
    daemon: ServiceDaemon,
}

impl Discovery {
    pub fn start(
        mut on_event: impl FnMut(DeviceEvent) + Send + 'static,
    ) -> Result<Self, DiscoveryError> {
        let daemon = ServiceDaemon::new().map_err(|e| DiscoveryError::Daemon(e.to_string()))?;
        let receiver = daemon
            .browse(SERVICE_TYPE)
            .map_err(|e| DiscoveryError::Daemon(e.to_string()))?;
        thread::spawn(move || {
            while let Ok(evento) = receiver.recv() {
                match evento {
                    ServiceEvent::ServiceResolved(info) => {
                        let mut addresses: Vec<Ipv4Addr> = info
                            .get_addresses_v4()
                            .into_iter()
                            .filter(|ip| !ip.is_link_local())
                            .collect();
                        addresses.sort();
                        if addresses.is_empty() {
                            continue;
                        }
                        let fullname = info.get_fullname().to_string();
                        on_event(DeviceEvent::Found(Device {
                            name: instance_name(&fullname),
                            id: fullname,
                            host: info.get_hostname().trim_end_matches('.').to_string(),
                            addresses,
                            port: info.get_port(),
                        }));
                    }
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        on_event(DeviceEvent::Lost { id: fullname });
                    }
                    ServiceEvent::SearchStopped(_) => break,
                    _ => {}
                }
            }
        });
        Ok(Self { daemon })
    }
}

impl Drop for Discovery {
    fn drop(&mut self) {
        let _ = self.daemon.stop_browse(SERVICE_TYPE);
        let _ = self.daemon.shutdown();
    }
}

pub fn instance_name(fullname: &str) -> String {
    fullname
        .strip_suffix(SERVICE_TYPE)
        .map(|n| n.trim_end_matches('.'))
        .unwrap_or(fullname)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nome_da_instancia_sem_o_tipo_do_servico() {
        assert_eq!(
            instance_name("Pixel 7._conectdroidcam._tcp.local."),
            "Pixel 7"
        );
        assert_eq!(instance_name("outro"), "outro");
    }

    #[test]
    fn endereco_usa_o_primeiro_ipv4_e_a_porta() {
        let d = Device {
            id: "x".into(),
            name: "x".into(),
            host: "h".into(),
            addresses: vec![Ipv4Addr::new(192, 168, 0, 7)],
            port: 47821,
        };
        assert_eq!(d.address().as_deref(), Some("192.168.0.7:47821"));
        let sem = Device {
            addresses: vec![],
            ..d
        };
        assert_eq!(sem.address(), None);
    }
}
