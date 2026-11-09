//! Uso: cdc-testreceiver HOST:PORTA [--seconds N] [--v4l2 /dev/videoN] [--dump arquivo.h264]
//!                       [--canvas auto|horizontal|vertical] [--size hd|fullhd|qhd] [--preview ARQUIVO.jpg] [--quiet]
//!                       [--do SEGUNDOS:COMANDO]...   (comandos ao celular: start:1280x720@30, stop, fps:24, camera:front|back|toggle)
//!        cdc-testreceiver --discover [SEGUNDOS]   (lista os celulares achados na rede)
//!
//! Ferramenta de validação sobre o `cdc-core`: conecta a um celular (ou ao `cdc-testsender`),
//! mede o fluxo e, opcionalmente, escreve o vídeo, já girado para ficar em pé, numa webcam
//! virtual.

use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use cdc_core::{
    Canvas, DeviceEvent, Discovery, OutputSize, SessionEvent, SessionOptions, StopHandle, connect,
    run,
};

/// Converte `start:1280x720@30`, `stop`, `fps:24` ou `camera:front` numa mensagem.
fn parse_command(texto: &str) -> Result<cdc_protocol::Message, String> {
    use cdc_protocol::{Facing, Message};
    let (nome, valor) = texto.split_once(':').unwrap_or((texto, ""));
    match nome {
        "start" => {
            let (tamanho, fps) = valor
                .split_once('@')
                .ok_or("use start:LARGURAxALTURA@FPS")?;
            let (w, h) = tamanho
                .split_once('x')
                .ok_or("use start:LARGURAxALTURA@FPS")?;
            let num = |t: &str| {
                t.parse::<u32>()
                    .map_err(|_| format!("número inválido: {t}"))
            };
            Ok(Message::StreamStart {
                width: num(w)?,
                height: num(h)?,
                fps: num(fps)?,
            })
        }
        "stop" => Ok(Message::StreamStop),
        "fps" => Ok(Message::FpsSet {
            fps: valor.parse().map_err(|_| "fps inválido".to_string())?,
        }),
        "camera" => Ok(Message::CameraSwitch {
            facing: match valor {
                "front" => Some(Facing::Front),
                "back" => Some(Facing::Back),
                "toggle" => None,
                _ => return Err("use camera:front, camera:back ou camera:toggle".into()),
            },
        }),
        outro => Err(format!("comando desconhecido: {outro}")),
    }
}

const USO: &str = "uso: cdc-testreceiver HOST:PORTA [--seconds N] [--v4l2 DISPOSITIVO] [--dump ARQUIVO] [--canvas auto|horizontal|vertical] [--preview ARQUIVO.jpg] [--quiet]";

/// Lista, por alguns segundos, o que a descoberta do app enxerga na rede.
fn discover(seconds: u64) -> ExitCode {
    let _busca = match Discovery::start(|evento| match evento {
        DeviceEvent::Found(d) => eprintln!(
            "achado: {} em {} (host {}, id {})",
            d.name,
            d.address().unwrap_or_default(),
            d.host,
            d.id
        ),
        DeviceEvent::Lost { id } => eprintln!("saiu: {id}"),
    }) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("erro: {e}");
            return ExitCode::FAILURE;
        }
    };
    eprintln!("procurando por {seconds} s...");
    std::thread::sleep(Duration::from_secs(seconds));
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.first().is_some_and(|a| a == "--discover") {
        let seconds = argv.get(1).and_then(|s| s.parse().ok()).unwrap_or(10);
        return discover(seconds);
    }
    let mut address = None;
    let mut options = SessionOptions {
        device_name: "cdc-testreceiver".into(),
        ..SessionOptions::default()
    };
    let mut verbose = true;
    let mut preview_file: Option<String> = None;
    let mut script: Vec<(u64, cdc_protocol::Message)> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or(format!("{name} precisa de um valor"));
        let parsed: Result<(), String> = match arg.as_str() {
            "--seconds" => value("--seconds").and_then(|v| {
                v.parse::<u64>()
                    .map(|s| options.duration = Some(Duration::from_secs(s)))
                    .map_err(|_| "segundos inválidos".into())
            }),
            "--v4l2" => value("--v4l2").map(|v| options.sink.v4l2 = Some(v)),
            "--dump" => value("--dump").map(|v| options.sink.dump = Some(v)),
            "--canvas" => value("--canvas").and_then(|v| match v.as_str() {
                "auto" => {
                    options.canvas = Canvas::Auto;
                    Ok(())
                }
                "horizontal" => {
                    options.canvas = Canvas::Horizontal;
                    Ok(())
                }
                "vertical" => {
                    options.canvas = Canvas::Vertical;
                    Ok(())
                }
                outro => Err(format!("formato desconhecido: {outro}")),
            }),
            "--size" => value("--size").and_then(|v| match v.as_str() {
                "hd" => {
                    options.output_size = OutputSize::Hd;
                    Ok(())
                }
                "fullhd" => {
                    options.output_size = OutputSize::FullHd;
                    Ok(())
                }
                "qhd" => {
                    options.output_size = OutputSize::Qhd;
                    Ok(())
                }
                outro => Err(format!("tamanho desconhecido: {outro}")),
            }),
            "--preview" => value("--preview").map(|v| {
                options.preview = true;
                preview_file = Some(v);
            }),
            "--do" => value("--do").and_then(|v| {
                let (quando, comando) = v.split_once(':').ok_or("use SEGUNDOS:COMANDO")?;
                let quando = quando
                    .parse()
                    .map_err(|_| "segundos inválidos".to_string())?;
                script.push((quando, parse_command(comando)?));
                Ok(())
            }),
            "--quiet" => {
                verbose = false;
                Ok(())
            }
            other if !other.starts_with("--") && address.is_none() => {
                address = Some(other.to_string());
                Ok(())
            }
            other => Err(format!("argumento desconhecido: {other}")),
        };
        if let Err(msg) = parsed {
            eprintln!("erro: {msg}\n{USO}");
            return ExitCode::from(2);
        }
    }
    let Some(address) = address else {
        eprintln!("{USO}");
        return ExitCode::from(2);
    };

    eprintln!("conectando a {address}...");
    let stream = match connect(&address, Duration::from_secs(5)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("erro: {e}");
            return ExitCode::FAILURE;
        }
    };
    let stop = StopHandle::new();
    if !script.is_empty() {
        let stop = stop.clone();
        thread::spawn(move || {
            let inicio = std::time::Instant::now();
            script.sort_by_key(|(quando, _)| *quando);
            for (quando, mensagem) in script {
                if let Some(falta) = Duration::from_secs(quando).checked_sub(inicio.elapsed()) {
                    thread::sleep(falta);
                }
                eprintln!("[{quando} s] enviando {mensagem:?}");
                if let Err(e) = stop.send(&mensagem) {
                    eprintln!("não consegui enviar: {e}");
                    return;
                }
            }
        });
    }
    let resultado = run(stream, &options, &stop, |evento| match evento {
        SessionEvent::Hello {
            device_name,
            platform,
        } => eprintln!("emissor: {device_name} ({platform})"),
        SessionEvent::Profile {
            width,
            height,
            fps,
            bitrate_kbps,
            rotation,
        } => eprintln!(
            "perfil real: {width}x{height} @ {fps} FPS, {bitrate_kbps} kb/s, rotação {rotation}°"
        ),
        SessionEvent::Output {
            canvas_width,
            canvas_height,
            rotation,
            device,
        } => eprintln!(
            "saída de vídeo: {canvas_width}x{canvas_height}, girada {rotation}°, em {}",
            device.as_deref().unwrap_or("nenhum dispositivo")
        ),
        SessionEvent::Capabilities {
            modes,
            fps_options,
            front,
            can_switch,
            streaming,
        } => {
            let disponiveis: Vec<String> = modes
                .iter()
                .filter(|m| m.available)
                .map(|m| format!("{}x{}", m.width, m.height))
                .collect();
            eprintln!(
                "celular: {} · câmera {} (troca: {}) · FPS {:?} · resoluções {}",
                if streaming { "transmitindo" } else { "parado" },
                if front { "frontal" } else { "traseira" },
                if can_switch { "sim" } else { "não" },
                fps_options,
                disponiveis.join(", ")
            );
        }
        SessionEvent::Notice(texto) => eprintln!("aviso: {texto}"),
        SessionEvent::SenderError { code, message } => {
            eprintln!("erro do emissor: {code}: {message}");
        }
        SessionEvent::Stats(s) if verbose => eprintln!(
            "{:5.1} fps  {:7.0} kb/s  atraso {:4.0} ms  total {} frames",
            s.fps, s.kbps, s.delay_ms, s.frames
        ),
        SessionEvent::Stats(_) => {}
        // Guarda o último quadro da prévia, para conferir a imagem a olho.
        SessionEvent::Preview(jpeg) => {
            if let Some(caminho) = &preview_file {
                let _ = std::fs::write(caminho, jpeg);
            }
        }
    });
    match resultado {
        Ok(report) => {
            eprintln!(
                "\nresumo: {} frames de vídeo ({} keyframes) em {:.1} s\n  média {:.1} FPS, {:.0} kb/s, maior intervalo entre frames {:.0} ms\n  atraso da rede além do melhor caso: p50 {:.0} ms, p95 {:.0} ms, máx {:.0} ms",
                report.video_frames,
                report.keyframes,
                report.seconds,
                report.avg_fps,
                report.avg_kbps,
                report.max_gap_ms,
                report.lag_p50_ms,
                report.lag_p95_ms,
                report.lag_max_ms
            );
            if report.video_frames == 0 {
                eprintln!("nenhum frame de vídeo recebido");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("erro: {e}");
            ExitCode::FAILURE
        }
    }
}
