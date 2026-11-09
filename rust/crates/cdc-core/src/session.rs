//! Uma sessão com um celular: conecta, lê o protocolo v1, mede o fluxo e entrega o vídeo à
//! webcam virtual, girado para ficar em pé.
//!
//! Não usa TLS nem faz pareamento: esta versão do protocolo ainda é aberta.

use std::io::{self, BufReader};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cdc_protocol::{Frame, FrameType, Message, Platform, ProtocolError};
use thiserror::Error;

use crate::filter::{Canvas, OutputSize, canvas_size, normalize_rotation, video_filter};
use crate::output::{DISCARD, Output, OutputError, Sink};
use crate::stats::{LagTracker, Report};
use crate::v4l2info::size_conflict_notice;

#[derive(Debug, Error)]
pub enum SessionError {
    #[error("endereço inválido: {0}")]
    BadAddress(String),
    #[error("não consegui conectar a {address}: {source}")]
    Connect { address: String, source: io::Error },
    #[error(transparent)]
    Output(#[from] OutputError),
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    #[error(transparent)]
    Io(#[from] io::Error),
}

#[derive(Debug, Clone)]
pub struct SessionOptions {
    /// Duração máxima da sessão. `None` roda até o emissor fechar ou até `StopHandle::stop`.
    pub duration: Option<Duration>,
    pub sink: Sink,
    pub ffmpeg: String,
    /// Formato do quadro de saída.
    pub canvas: Canvas,
    /// Tamanho do quadro de saída. Não acompanha a resolução do celular.
    pub output_size: OutputSize,
    /// Dispositivos por tamanho e formato. Se houver um para o par em uso, é nele que se
    /// escreve; senão, em `sink.v4l2`.
    pub shape_devices: Vec<ShapeDevice>,
    /// Nome deste computador, mostrado no celular.
    pub device_name: String,
    /// Gera quadros JPEG pequenos para uma prévia na tela ([`SessionEvent::Preview`]).
    pub preview: bool,
}

impl Default for SessionOptions {
    fn default() -> Self {
        Self {
            duration: None,
            sink: Sink::default(),
            ffmpeg: "ffmpeg".into(),
            canvas: Canvas::default(),
            output_size: OutputSize::default(),
            shape_devices: Vec::new(),
            device_name: "computador".into(),
            preview: false,
        }
    }
}

/// Um dispositivo de webcam virtual que sempre tem o mesmo tamanho: o do par (tamanho,
/// formato). O OBS nunca fecha a webcam que abriu e ela não muda de tamanho com ele aberto;
/// por isso há um dispositivo por tamanho e formato, e o app escolhe o certo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShapeDevice {
    pub size: OutputSize,
    /// `Horizontal` ou `Vertical` (nunca `Auto`).
    pub canvas: Canvas,
    pub path: String,
}

/// Estatísticas da última janela de um segundo.
#[derive(Debug, Clone, PartialEq)]
pub struct Stats {
    pub fps: f64,
    pub kbps: f64,
    pub frames: u64,
    pub keyframes: u64,
    /// Maior atraso da rede na janela, além do melhor caso observado, em ms.
    pub delay_ms: f64,
}

/// O que acontece durante uma sessão.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionEvent {
    /// O emissor se apresentou.
    Hello {
        device_name: String,
        platform: String,
    },
    /// O que o emissor está realmente entregando.
    Profile {
        width: u32,
        height: u32,
        fps: u32,
        bitrate_kbps: u32,
        rotation: u32,
    },
    /// A saída de vídeo foi (re)iniciada neste tamanho, com esta rotação aplicada.
    Output {
        canvas_width: u32,
        canvas_height: u32,
        rotation: u32,
        /// Dispositivo de vídeo em que a imagem está sendo escrita, se houver.
        device: Option<String>,
    },
    Stats(Stats),
    /// Um quadro JPEG da prévia (cerca de 10 por segundo, 480 px de largura).
    Preview(Vec<u8>),
    /// O emissor reportou um erro.
    SenderError {
        code: String,
        message: String,
    },
    /// Algo a mostrar ao usuário que não interrompe a sessão.
    Notice(String),
}

/// Permite encerrar uma sessão de outra thread.
#[derive(Clone, Default)]
pub struct StopHandle {
    inner: Arc<StopInner>,
}

#[derive(Default)]
struct StopInner {
    stopped: AtomicBool,
    stream: Mutex<Option<TcpStream>>,
}

impl StopHandle {
    pub fn new() -> Self {
        Self::default()
    }

    /// Pede o fim da sessão e desbloqueia a leitura que esteja esperando o celular.
    pub fn stop(&self) {
        self.inner.stopped.store(true, Ordering::SeqCst);
        if let Ok(mut guard) = self.inner.stream.lock()
            && let Some(stream) = guard.take()
        {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }

    pub fn is_stopped(&self) -> bool {
        self.inner.stopped.load(Ordering::SeqCst)
    }

    fn attach(&self, stream: &TcpStream) -> io::Result<()> {
        let clone = stream.try_clone()?;
        if let Ok(mut guard) = self.inner.stream.lock() {
            *guard = Some(clone);
        }
        // Se o fim foi pedido antes de a sessão começar, já fecha.
        if self.is_stopped() {
            self.stop();
        }
        Ok(())
    }
}

/// Abre a conexão com o celular, com prazo, preferindo IPv4.
pub fn connect(address: &str, timeout: Duration) -> Result<TcpStream, SessionError> {
    let mut alvos: Vec<_> = address
        .to_socket_addrs()
        .map_err(|e| SessionError::BadAddress(format!("{address} ({e})")))?
        .collect();
    alvos.sort_by_key(|a| !a.is_ipv4());
    let mut ultimo = None;
    for alvo in alvos {
        match TcpStream::connect_timeout(&alvo, timeout) {
            Ok(s) => return Ok(s),
            Err(e) => ultimo = Some(e),
        }
    }
    Err(SessionError::Connect {
        address: address.to_string(),
        source: ultimo.unwrap_or_else(|| io::Error::other("sem endereços")),
    })
}

fn is_disconnect(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::UnexpectedEof
    )
}

fn send(stream: &mut TcpStream, message: &Message) -> Result<(), SessionError> {
    message.to_frame(0)?.write_to(stream)?;
    Ok(())
}

#[derive(Clone, Copy)]
struct Profile {
    width: u32,
    height: u32,
    rotation: u32,
}

/// Filtro e tamanho do quadro de saída para o perfil atual. `resolved` guarda o formato
/// escolhido na primeira vez que há um perfil e o mantém pelo resto da sessão: o tamanho da
/// webcam virtual não pode mudar no meio dela.
fn desired_output(
    profile: Option<Profile>,
    canvas: Canvas,
    size: OutputSize,
    resolved: &mut Option<Canvas>,
) -> (Option<String>, Option<(u32, u32)>) {
    match profile {
        Some(p) => {
            let canvas = *resolved.get_or_insert_with(|| canvas.resolve(p.rotation));
            let (cw, ch) = canvas_size(size, canvas);
            (
                video_filter(p.width, p.height, p.rotation, cw, ch),
                Some((cw, ch)),
            )
        }
        None => (None, None),
    }
}

/// Roda uma sessão completa em uma conexão já aberta. Termina quando o tempo acaba, o
/// celular fecha a conexão ou `stop` é chamado.
pub fn run(
    stream: TcpStream,
    options: &SessionOptions,
    stop: &StopHandle,
    mut on_event: impl FnMut(SessionEvent),
) -> Result<Report, SessionError> {
    stream.set_nodelay(true)?;
    stop.attach(&stream)?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut output = Output::new(&options.sink, &options.ffmpeg, options.preview)?;

    let platform = if cfg!(target_os = "macos") {
        Platform::Macos
    } else {
        Platform::Linux
    };
    send(
        &mut writer,
        &Message::Hello {
            device_name: options.device_name.clone(),
            platform,
            app_version: env!("CARGO_PKG_VERSION").into(),
        },
    )?;
    send(&mut writer, &Message::ProfileQuery)?;
    // O celular só começa a enviar vídeo útil num keyframe; pedir um logo acelera a prévia.
    send(&mut writer, &Message::KeyframeRequest)?;

    let started = Instant::now();
    let mut report = Report::default();
    let mut lag = LagTracker::default();
    let mut config: Option<Vec<u8>> = None;
    let mut profile: Option<Profile> = None;
    let mut feeding = false;
    // Formato de saída em uso: resolvido uma vez e mantido durante a sessão.
    let mut canvas_in_use: Option<Canvas> = None;
    let mut last_video: Option<Instant> = None;
    let mut window_start = Instant::now();
    let (mut window_frames, mut window_bytes) = (0u64, 0u64);

    let resultado: Result<(), SessionError> = (|| {
        loop {
            if stop.is_stopped() || options.duration.is_some_and(|d| started.elapsed() >= d) {
                return Ok(());
            }
            let frame = match Frame::read_from(&mut reader) {
                Ok(Some(frame)) => frame,
                Ok(None) => return Ok(()),
                // O celular pode cair ou o app fechar no meio da sessão, ou o fim ter sido
                // pedido: o relatório do que já chegou continua valendo.
                Err(ProtocolError::Io(e)) if is_disconnect(&e) || stop.is_stopped() => {
                    return Ok(());
                }
                Err(e) => return Err(e.into()),
            };
            match frame.kind {
                FrameType::Control => match Message::from_frame(&frame)? {
                    Message::ProfileActual {
                        width,
                        height,
                        fps,
                        bitrate_kbps,
                        rotation,
                    } => {
                        let rotation = normalize_rotation(rotation);
                        profile = Some(Profile {
                            width,
                            height,
                            rotation,
                        });
                        report.actual = Some((width, height, fps));
                        on_event(SessionEvent::Profile {
                            width,
                            height,
                            fps,
                            bitrate_kbps,
                            rotation,
                        });
                        // Se a saída já roda com outro filtro (o celular girou), pede um
                        // keyframe para reiniciá-la sem esperar o próximo natural.
                        let (filter, _) = desired_output(
                            profile,
                            options.canvas,
                            options.output_size,
                            &mut canvas_in_use,
                        );
                        if output.has_process() && !output.is_running_with(&filter) {
                            send(&mut writer, &Message::KeyframeRequest)?;
                        }
                    }
                    Message::Error { code, message } => on_event(SessionEvent::SenderError {
                        code: format!("{code:?}"),
                        message,
                    }),
                    Message::SessionStop => return Ok(()),
                    Message::Hello {
                        device_name,
                        platform,
                        ..
                    } => on_event(SessionEvent::Hello {
                        device_name,
                        platform: format!("{platform:?}").to_lowercase(),
                    }),
                    _ => {}
                },
                FrameType::VideoConfig => {
                    report.received_config = true;
                    config = Some(frame.payload);
                }
                FrameType::Video => {
                    let now = Instant::now();
                    if let Some(previous) = last_video {
                        let gap = now.duration_since(previous).as_secs_f64() * 1000.0;
                        report.max_gap_ms = report.max_gap_ms.max(gap);
                    }
                    last_video = Some(now);
                    lag.record(now, frame.pts_us);

                    // Só começa a entregar, e só reinicia a saída, num keyframe. O SPS/PPS
                    // enviado à parte vai primeiro, se existir; sem ele, o próprio keyframe o
                    // carrega, porque o codificador repete SPS/PPS em cada IDR.
                    if frame.is_keyframe() {
                        let (filter, dims) = desired_output(
                            profile,
                            options.canvas,
                            options.output_size,
                            &mut canvas_in_use,
                        );
                        let mudou = output.has_process() && !output.is_running_with(&filter);
                        if !feeding || mudou {
                            // Com dispositivos por tamanho e formato, escreve no que combina
                            // com o par em uso; senão, no dispositivo único configurado.
                            let escolhido = canvas_in_use.and_then(|c| {
                                options
                                    .shape_devices
                                    .iter()
                                    .find(|d| d.size == options.output_size && d.canvas == c)
                                    .map(|d| d.path.clone())
                            });
                            if !feeding
                                && !options.shape_devices.is_empty()
                                && escolhido.is_none()
                                && options.sink.v4l2.is_none()
                            {
                                on_event(SessionEvent::Notice(format!(
                                    "Não há uma webcam virtual para {:?} {:?}. Rode \
                                     scripts/setup/linux-webcam-virtual.sh de novo para criá-las.",
                                    options.output_size, canvas_in_use
                                )));
                            }
                            let dispositivo_em_uso =
                                escolhido.or_else(|| options.sink.v4l2.clone());
                            output.set_device(dispositivo_em_uso.clone());
                            // Alguém (o OBS) já pode ter a webcam virtual aberta em outro
                            // tamanho; avisa antes de escrever, que é quando ainda dá para agir.
                            if let (Some(dispositivo), Some(tamanho), false) =
                                (&dispositivo_em_uso, dims, mudou)
                                && !dispositivo.starts_with(DISCARD)
                                && let Some(aviso) =
                                    size_conflict_notice(dispositivo, tamanho, std::process::id())
                            {
                                on_event(SessionEvent::Notice(aviso));
                            }
                            output.start(filter)?;
                            if let Some(cfg) = &config {
                                output.write(cfg)?;
                            }
                            feeding = true;
                            if let (Some((canvas_width, canvas_height)), Some(p)) = (dims, profile)
                            {
                                on_event(SessionEvent::Output {
                                    canvas_width,
                                    canvas_height,
                                    rotation: p.rotation,
                                    device: dispositivo_em_uso.clone(),
                                });
                            }
                        }
                    }
                    if feeding {
                        output.write(&frame.payload)?;
                    }

                    report.video_frames += 1;
                    report.keyframes += u64::from(frame.is_keyframe());
                    report.bytes += frame.payload.len() as u64;
                    window_frames += 1;
                    window_bytes += frame.payload.len() as u64;
                }
                FrameType::AudioConfig | FrameType::Audio => {}
            }

            while let Some(quadro) = output.next_preview() {
                on_event(SessionEvent::Preview(quadro));
            }

            let janela = window_start.elapsed();
            if janela >= Duration::from_secs(1) {
                let secs = janela.as_secs_f64();
                on_event(SessionEvent::Stats(Stats {
                    fps: window_frames as f64 / secs,
                    kbps: window_bytes as f64 * 8.0 / 1000.0 / secs,
                    frames: report.video_frames,
                    keyframes: report.keyframes,
                    delay_ms: lag.take_window_max(),
                }));
                window_start = Instant::now();
                window_frames = 0;
                window_bytes = 0;
            }
        }
    })();

    // Em qualquer saída, avisa o celular e fecha a saída de vídeo.
    let _ = send(&mut writer, &Message::SessionStop);
    output.finish();
    let _ = writer.shutdown(Shutdown::Both);
    resultado?;

    report.seconds = started.elapsed().as_secs_f64();
    lag.fill(&mut report);
    if report.seconds > 0.0 {
        report.avg_fps = report.video_frames as f64 / report.seconds;
        report.avg_kbps = report.bytes as f64 * 8.0 / 1000.0 / report.seconds;
    }
    Ok(report)
}
