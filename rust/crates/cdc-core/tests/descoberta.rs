use std::sync::mpsc;
use std::time::{Duration, Instant};

use cdc_core::{DeviceEvent, Discovery, SERVICE_TYPE};
use mdns_sd::{ServiceDaemon, ServiceInfo};

#[test]
#[ignore = "precisa de multicast na rede local"]
fn acha_um_celular_anunciado_e_percebe_quando_ele_sai() {
    let nome = format!("Teste CDC {}", std::process::id());
    let anunciante = ServiceDaemon::new().expect("daemon");
    let info = ServiceInfo::new(
        SERVICE_TYPE,
        &nome,
        &format!("{}.local.", nome.replace(' ', "-")),
        "",
        47821,
        &[("version", "test")][..],
    )
    .expect("info")
    .enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    anunciante.register(info).expect("registro");

    let (tx, rx) = mpsc::channel();
    let _busca = Discovery::start(move |e| {
        let _ = tx.send(e);
    })
    .expect("busca");

    let prazo = Instant::now() + Duration::from_secs(15);
    let achado = loop {
        let restante = prazo.saturating_duration_since(Instant::now());
        match rx
            .recv_timeout(restante)
            .expect("não achou o serviço em 15 s")
        {
            DeviceEvent::Found(d) if d.id == fullname => break d,
            _ => {}
        }
    };
    assert_eq!(achado.name, nome);
    assert_eq!(achado.port, 47821);
    assert!(achado.address().is_some(), "sem endereço IPv4: {achado:?}");

    let _ = anunciante.unregister(&fullname);
    let prazo = Instant::now() + Duration::from_secs(15);
    loop {
        let restante = prazo.saturating_duration_since(Instant::now());
        match rx
            .recv_timeout(restante)
            .expect("não percebeu a saída em 15 s")
        {
            DeviceEvent::Lost { id } if id == fullname => break,
            _ => {}
        }
    }
    let _ = anunciante.shutdown();
}
