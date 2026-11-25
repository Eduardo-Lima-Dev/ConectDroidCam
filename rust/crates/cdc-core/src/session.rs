use std::io::{self, BufReader};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cdc_protocol::{
    CapabilityMode, ErrorCode, Facing, Frame, FrameType, Message, Platform, ProtocolError,
};
use cdc_security::{Identity, SecError, SecureLink, connect_secure, new_nonce, pairing_code};
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
    #[error("{0}")]
    Security(String),
}

impl From<SecError> for SessionError {
    fn from(e: SecError) -> Self {
        Self::Security(match e {
            SecError::FingerprintMismatch { .. } => {
                "O certificado deste celular mudou desde o pareamento. Pode ser outro aparelho \
                 fingindo ser ele. Remova o pareamento e pareie de novo se foi você quem \
                 reinstalou o app."
                    .to_string()
            }
            outro => outro.to_string(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct SessionOptions {
    pub duration: Option<Duration>,
    pub sink: Sink,
    pub ffmpeg: String,
    pub canvas: Canvas,
    pub output_size: OutputSize,
    pub shape_devices: Vec<ShapeDevice>,
    pub device_name: String,
    pub own_fingerprint: String,
    pub phone_fingerprint: String,
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
            own_fingerprint: String::new(),
            phone_fingerprint: String::new(),
            preview: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShapeDevice {
    pub size: OutputSize,
    pub canvas: Canvas,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Stats {
    pub fps: f64,
    pub kbps: f64,
    pub frames: u64,
    pub keyframes: u64,
    pub delay_ms: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SessionEvent {
    Hello {
        device_name: String,
        platform: String,
    },
    Profile {
        width: u32,
        height: u32,
        fps: u32,
        bitrate_kbps: u32,
        rotation: u32,
    },
    Output {
        canvas_width: u32,
        canvas_height: u32,
        rotation: u32,
        device: Option<String>,
    },
    Stats(Stats),
    Preview(Vec<u8>),
    Capabilities {
        modes: Vec<CapabilityMode>,
        fps_options: Vec<u32>,
        front: bool,
        can_switch: bool,
        streaming: bool,
    },
    PairingCode {
        code: String,
        phone_fingerprint: String,
    },
    Paired {
        phone_fingerprint: String,
    },
    PairingDenied {
        reason: String,
    },
    SenderError {
        code: String,
        message: String,
    },
    Notice(String),
}

#[derive(Clone, Default)]
pub struct StopHandle {
    inner: Arc<StopInner>,
}

#[derive(Default)]
struct StopInner {
    stopped: AtomicBool,
    stream: Mutex<Option<TcpStream>>,
    pairing_nonce: Mutex<Option<String>>,
}

impl StopHandle {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn stop(&self) {
        self.inner.stopped.store(true, Ordering::SeqCst);
        if let Ok(mut guard) = self.inner.stream.lock()
            && let Some(stream) = guard.take()
        {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }

    pub fn send(&self, message: &Message) -> Result<(), SessionError> {
        let frame = message.to_frame(0)?;
        let mut guard = self
            .inner
            .stream
            .lock()
            .map_err(|_| io::Error::other("estado interno corrompido"))?;
        let stream = guard
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "sem sessão ativa"))?;
        frame.write_to(stream)?;
        Ok(())
    }

    pub fn confirm_pairing(&self, accept: bool) -> Result<(), SessionError> {
        let nonce = self
            .inner
            .pairing_nonce
            .lock()
            .map_err(|_| io::Error::other("estado interno corrompido"))?
            .clone()
            .ok_or_else(|| SessionError::Security("não há pareamento em andamento".into()))?;
        self.send(&Message::PairConfirm {
            nonce,
            confirmed: accept,
        })
    }

    fn set_pairing_nonce(&self, nonce: Option<String>) {
        if let Ok(mut guard) = self.inner.pairing_nonce.lock() {
            *guard = nonce;
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
        if self.is_stopped() {
            self.stop();
        }
        Ok(())
    }
}

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

pub fn connect_secure_phone(
    address: &str,
    timeout: Duration,
    identity: &Identity,
    pinned: Option<&str>,
) -> Result<SecureLink, SessionError> {
    let tcp = connect(address, timeout)?;
    Ok(connect_secure(tcp, identity, pinned)?)
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

#[derive(Clone, Copy)]
struct Profile {
    width: u32,
    height: u32,
    rotation: u32,
}

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

pub fn run(
    stream: TcpStream,
    options: &SessionOptions,
    stop: &StopHandle,
    mut on_event: impl FnMut(SessionEvent),
) -> Result<Report, SessionError> {
    stream.set_nodelay(true)?;
    stop.attach(&stream)?;
    let mut reader = BufReader::new(stream);
    let mut output = Output::new(&options.sink, &options.ffmpeg, options.preview)?;

    let platform = if cfg!(target_os = "macos") {
        Platform::Macos
    } else {
        Platform::Linux
    };
    stop.send(&Message::Hello {
        device_name: options.device_name.clone(),
        platform,
        app_version: env!("CARGO_PKG_VERSION").into(),
    })?;
    stop.send(&Message::ProfileQuery)?;
    stop.send(&Message::KeyframeRequest)?;

    let started = Instant::now();
    let mut pairing: Option<String> = None;
    let mut report = Report::default();
    let mut lag = LagTracker::default();
    let mut config: Option<Vec<u8>> = None;
    let mut profile: Option<Profile> = None;
    let mut feeding = false;
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
                    } if width > 0 && height > 0 => {
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
                        let (filter, _) = desired_output(
                            profile,
                            options.canvas,
                            options.output_size,
                            &mut canvas_in_use,
                        );
                        if output.has_process() && !output.is_running_with(&filter) {
                            stop.send(&Message::KeyframeRequest)?;
                        }
                    }
                    Message::ProfileActual { .. } => {}
                    Message::Capabilities {
                        modes,
                        fps_options,
                        facing,
                        can_switch,
                        streaming,
                    } => {
                        if !streaming && (feeding || profile.is_some()) {
                            output.finish();
                            feeding = false;
                            profile = None;
                            config = None;
                            last_video = None;
                        }
                        on_event(SessionEvent::Capabilities {
                            modes,
                            fps_options,
                            front: facing == Facing::Front,
                            can_switch,
                            streaming,
                        });
                    }
                    Message::Error {
                        code: ErrorCode::AuthFailed,
                        ..
                    } if pairing.is_none()
                        && !options.phone_fingerprint.is_empty()
                        && !options.own_fingerprint.is_empty() =>
                    {
                        let nonce = new_nonce()?;
                        let code = pairing_code(
                            &options.phone_fingerprint,
                            &options.own_fingerprint,
                            &nonce,
                        );
                        stop.set_pairing_nonce(Some(nonce.clone()));
                        stop.send(&Message::PairRequest { nonce })?;
                        pairing = Some(code.clone());
                        on_event(SessionEvent::PairingCode {
                            code,
                            phone_fingerprint: options.phone_fingerprint.clone(),
                        });
                    }
                    Message::PairConfirm { confirmed, .. } if pairing.is_some() => {
                        pairing = None;
                        stop.set_pairing_nonce(None);
                        if confirmed {
                            on_event(SessionEvent::Paired {
                                phone_fingerprint: options.phone_fingerprint.clone(),
                            });
                            stop.send(&Message::ProfileQuery)?;
                            stop.send(&Message::KeyframeRequest)?;
                        } else {
                            on_event(SessionEvent::PairingDenied {
                                reason: "O celular recusou o pareamento.".into(),
                            });
                            return Ok(());
                        }
                    }
                    Message::PairDenied { reason } => {
                        on_event(SessionEvent::PairingDenied { reason });
                        return Ok(());
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

                    if frame.is_keyframe() {
                        let (filter, dims) = desired_output(
                            profile,
                            options.canvas,
                            options.output_size,
                            &mut canvas_in_use,
                        );
                        let mudou = output.has_process() && !output.is_running_with(&filter);
                        if !feeding || mudou {
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

    let _ = stop.send(&Message::SessionStop);
    output.finish();
    stop.stop();
    resultado?;

    report.seconds = started.elapsed().as_secs_f64();
    lag.fill(&mut report);
    if report.seconds > 0.0 {
        report.avg_fps = report.video_frames as f64 / report.seconds;
        report.avg_kbps = report.bytes as f64 * 8.0 / 1000.0 / report.seconds;
    }
    Ok(report)
}
