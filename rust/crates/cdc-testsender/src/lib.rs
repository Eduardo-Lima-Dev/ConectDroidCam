pub mod annexb;

use std::io::{self, BufWriter, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cdc_protocol::{
    CapabilityMode, ErrorCode, FLAG_KEYFRAME, Facing, Frame, FrameType, Message, Platform,
    ProtocolError, VideoProfile,
};
use thiserror::Error;

use crate::annexb::{AccessUnitSplitter, extract_config, is_keyframe};

const FPS: u32 = 30;

#[derive(Debug, Error)]
pub enum SenderError {
    #[error("não consegui iniciar o ffmpeg: {0}")]
    Ffmpeg(io::Error),
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    #[error(transparent)]
    Io(#[from] io::Error),
}

#[derive(Debug, Clone)]
pub struct Options {
    pub profile: VideoProfile,
    pub seconds: u32,
    pub ffmpeg: String,
    pub rotation: u32,
    pub rotate_after: Option<(u32, u32)>,
}

impl Options {
    pub fn new(profile: VideoProfile, seconds: u32) -> Self {
        Self {
            profile,
            seconds,
            ffmpeg: "ffmpeg".into(),
            rotation: 0,
            rotate_after: None,
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Summary {
    pub video_frames: u64,
    pub keyframes: u64,
}

pub fn serve_connection(stream: TcpStream, options: &Options) -> Result<Summary, SenderError> {
    stream.set_nodelay(true)?;
    let mut out = BufWriter::new(stream);
    let (width, height) = options.profile.dimensions();
    let (min, max) = options.profile.bitrate_range_kbps();
    let bitrate = (min + max) / 2;

    Message::Hello {
        device_name: "cdc-testsender".into(),
        platform: Platform::Linux,
        app_version: env!("CARGO_PKG_VERSION").into(),
    }
    .to_frame(0)?
    .write_to(&mut out)?;
    send_profile(&mut out, width, height, bitrate, options.rotation)?;
    out.flush()?;

    let (drained_tx, drained_rx) = mpsc::channel();
    let drain = {
        let mut input = out.get_ref().try_clone()?;
        thread::spawn(move || {
            while let Ok(Some(_)) = Frame::read_from(&mut input) {}
            let _ = drained_tx.send(());
        })
    };

    let result = stream_segments(&mut out, options, width, height, bitrate);

    let _ = out.flush();
    let socket = out.get_ref();
    let _ = socket.shutdown(Shutdown::Write);
    let _ = drained_rx.recv_timeout(Duration::from_secs(2));
    let _ = socket.shutdown(Shutdown::Both);
    let _ = drain.join();
    result
}

fn send_profile<W: Write>(
    out: &mut W,
    width: u32,
    height: u32,
    bitrate: u32,
    rotation: u32,
) -> Result<(), SenderError> {
    Message::ProfileActual {
        width,
        height,
        fps: FPS,
        bitrate_kbps: bitrate,
        rotation,
    }
    .to_frame(0)?
    .write_to(out)?;
    Ok(())
}

fn sensor_filter(rotation: u32) -> Option<&'static str> {
    match rotation {
        90 => Some("transpose=2"),
        180 => Some("transpose=1,transpose=1"),
        270 => Some("transpose=1"),
        _ => None,
    }
}

fn spawn_ffmpeg(
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
    rotation: u32,
    seconds: u32,
) -> Result<Child, SenderError> {
    let rate = format!("{bitrate}k");
    let (cena_w, cena_h) = if !rotation.is_multiple_of(180) {
        (height, width)
    } else {
        (width, height)
    };
    let mut cmd = Command::new(&options.ffmpeg);
    cmd.args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-re",
        "-f",
        "lavfi",
        "-i",
    ])
    .arg(format!("testsrc2=size={cena_w}x{cena_h}:rate={FPS}"));
    if let Some(filtro) = sensor_filter(rotation) {
        cmd.args(["-vf", filtro]);
    }
    cmd.args([
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
    ])
    .args(["-profile:v", "high", "-pix_fmt", "yuv420p", "-g", "30"])
    .args(["-b:v", &rate, "-maxrate", &rate, "-bufsize", &rate])
    .args(["-bsf:v", "h264_metadata=aud=insert"])
    .args(["-t", &seconds.to_string(), "-f", "h264", "-"])
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit())
    .spawn()
    .map_err(SenderError::Ffmpeg)
}

#[derive(Default)]
struct Shared {
    summary: Summary,
    config_sent: bool,
    epoch: Option<Instant>,
}

fn stream_segments<W: Write>(
    out: &mut W,
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
) -> Result<Summary, SenderError> {
    let mut shared = Shared::default();
    let primeiro = options
        .rotate_after
        .map_or(options.seconds, |(s, _)| s.min(options.seconds));
    let completo = stream_segment(
        out,
        options,
        width,
        height,
        bitrate,
        options.rotation,
        primeiro,
        &mut shared,
    )?;
    if let Some((depois, nova)) = options.rotate_after
        && completo
        && depois < options.seconds
    {
        send_profile(out, width, height, bitrate, nova)?;
        out.flush()?;
        stream_segment(
            out,
            options,
            width,
            height,
            bitrate,
            nova,
            options.seconds - depois,
            &mut shared,
        )?;
    }
    Ok(shared.summary)
}

#[allow(clippy::too_many_arguments)]
fn stream_segment<W: Write>(
    out: &mut W,
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
    rotation: u32,
    seconds: u32,
    shared: &mut Shared,
) -> Result<bool, SenderError> {
    let mut child = spawn_ffmpeg(options, width, height, bitrate, rotation, seconds)?;
    let resultado = stream_video(&mut child, out, shared);
    let _ = child.kill();
    let _ = child.wait();
    resultado
}

fn stream_video<W: Write>(
    child: &mut Child,
    out: &mut W,
    shared: &mut Shared,
) -> Result<bool, SenderError> {
    let Some(mut stdout) = child.stdout.take() else {
        return Err(SenderError::Io(io::Error::other("ffmpeg sem stdout")));
    };
    let mut splitter = AccessUnitSplitter::new();
    let mut chunk = vec![0u8; 64 * 1024];

    loop {
        let read = stdout.read(&mut chunk)?;
        let units = if read == 0 {
            splitter.push(&[0, 0, 0, 1, 0x09, 0xf0])
        } else {
            splitter.push(&chunk[..read])
        };
        for unit in units {
            if !shared.config_sent
                && let Some(config) = extract_config(&unit)
            {
                Frame::new(FrameType::VideoConfig, 0, 0, config).write_to(out)?;
                shared.config_sent = true;
            }
            let keyframe = is_keyframe(&unit);
            let pts = shared.summary.video_frames * 1_000_000 / u64::from(FPS);
            let target =
                *shared.epoch.get_or_insert_with(Instant::now) + Duration::from_micros(pts);
            if let Some(wait) = target.checked_duration_since(Instant::now()) {
                thread::sleep(wait);
            }
            let flags = if keyframe { FLAG_KEYFRAME } else { 0 };
            if let Err(e) = Frame::new(FrameType::Video, flags, pts, unit).write_to(out) {
                return if is_disconnect(&e) {
                    Ok(false)
                } else {
                    Err(e.into())
                };
            }
            shared.summary.video_frames += 1;
            shared.summary.keyframes += u64::from(keyframe);
        }
        if let Err(e) = out.flush() {
            return if is_disconnect_io(&e) {
                Ok(false)
            } else {
                Err(e.into())
            };
        }
        if read == 0 {
            return Ok(true);
        }
    }
}

fn is_disconnect(error: &ProtocolError) -> bool {
    matches!(error, ProtocolError::Io(e) if is_disconnect_io(e))
}

fn is_disconnect_io(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
    )
}

struct SharedWriter {
    socket: Arc<Mutex<TcpStream>>,
    pending: Vec<u8>,
    stop: Arc<AtomicBool>,
}

impl Write for SharedWriter {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.pending.extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        if self.stop.load(Ordering::SeqCst) {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "transmissão parada",
            ));
        }
        let mut socket = self
            .socket
            .lock()
            .map_err(|_| io::Error::other("estado interno corrompido"))?;
        let result = socket
            .write_all(&self.pending)
            .and_then(|()| socket.flush());
        self.pending.clear();
        result
    }
}

struct Phone {
    socket: Arc<Mutex<TcpStream>>,
    options: Options,
    front: bool,
    running: Option<(Arc<AtomicBool>, thread::JoinHandle<()>)>,
    fps: u32,
    size: (u32, u32),
}

const SIM_MODES: [(u32, u32, bool); 3] =
    [(1280, 720, true), (1920, 1080, true), (2560, 1440, false)];

impl Phone {
    fn send(&self, message: &Message) -> Result<(), SenderError> {
        let frame = message.to_frame(0)?;
        let mut socket = self
            .socket
            .lock()
            .map_err(|_| io::Error::other("estado interno corrompido"))?;
        frame.write_to(&mut *socket)?;
        socket.flush()?;
        Ok(())
    }

    fn streaming(&self) -> bool {
        self.running.is_some()
    }

    fn send_capabilities(&self) -> Result<(), SenderError> {
        self.send(&Message::Capabilities {
            modes: SIM_MODES
                .iter()
                .map(|&(width, height, available)| CapabilityMode {
                    width,
                    height,
                    available,
                    max_fps: 30,
                    reason: (!available).then(|| "sem codificador H.264 por hardware".to_string()),
                })
                .collect(),
            fps_options: vec![15, 24, 30],
            facing: if self.front {
                Facing::Front
            } else {
                Facing::Back
            },
            can_switch: true,
            streaming: self.streaming(),
        })
    }

    fn send_profile_now(&self) -> Result<(), SenderError> {
        let mut socket = self
            .socket
            .lock()
            .map_err(|_| io::Error::other("estado interno corrompido"))?;
        send_profile(
            &mut *socket,
            self.size.0,
            self.size.1,
            4000,
            self.options.rotation,
        )?;
        socket.flush()?;
        Ok(())
    }

    fn fail(&self, message: &str) -> Result<(), SenderError> {
        self.send(&Message::Error {
            code: ErrorCode::CommandFailed,
            message: message.into(),
        })
    }

    fn start(&mut self, width: u32, height: u32, fps: u32) -> Result<(), SenderError> {
        if self.streaming() {
            return self.fail("já está transmitindo");
        }
        if !SIM_MODES
            .iter()
            .any(|&(w, h, ok)| ok && w == width && h == height)
        {
            return self.fail("resolução indisponível neste aparelho");
        }
        self.size = (width, height);
        self.fps = fps;
        let stop = Arc::new(AtomicBool::new(false));
        let mut writer = SharedWriter {
            socket: Arc::clone(&self.socket),
            pending: Vec::new(),
            stop: Arc::clone(&stop),
        };
        let handle = {
            let options = Options {
                seconds: 3600,
                ..self.options.clone()
            };
            thread::spawn(move || {
                let mut shared = Shared::default();
                if let Ok(mut child) =
                    spawn_ffmpeg(&options, width, height, 4000, options.rotation, 3600)
                {
                    let _ = stream_video(&mut child, &mut writer, &mut shared);
                    let _ = child.kill();
                    let _ = child.wait();
                }
            })
        };
        self.running = Some((stop, handle));
        self.send_profile_now()?;
        self.send_capabilities()
    }

    fn stop(&mut self) -> Result<(), SenderError> {
        if let Some((flag, handle)) = self.running.take() {
            flag.store(true, Ordering::SeqCst);
            let _ = handle.join();
        }
        self.send_capabilities()
    }
}

pub fn serve_controllable(stream: TcpStream, options: &Options) -> Result<(), SenderError> {
    stream.set_nodelay(true)?;
    let mut input = stream.try_clone()?;
    let mut phone = Phone {
        socket: Arc::new(Mutex::new(stream)),
        options: options.clone(),
        front: false,
        running: None,
        fps: 30,
        size: options.profile.dimensions(),
    };
    phone.send(&Message::Hello {
        device_name: "cdc-testsender".into(),
        platform: Platform::Linux,
        app_version: env!("CARGO_PKG_VERSION").into(),
    })?;
    phone.send_capabilities()?;

    let resultado = loop {
        let frame = match Frame::read_from(&mut input) {
            Ok(Some(frame)) => frame,
            Ok(None) => break Ok(()),
            Err(e) if is_disconnect(&e) => break Ok(()),
            Err(e) => break Err(e.into()),
        };
        if frame.kind != FrameType::Control {
            continue;
        }
        let outcome = match Message::from_frame(&frame) {
            Ok(Message::StreamStart { width, height, fps }) => phone.start(width, height, fps),
            Ok(Message::StreamStop) => phone.stop(),
            Ok(Message::FpsSet { fps }) => {
                phone.fps = fps;
                phone.send_profile_now()
            }
            Ok(Message::CameraSwitch { facing }) => {
                phone.front = facing.map_or(!phone.front, |f| f == Facing::Front);
                phone.send_capabilities()
            }
            Ok(Message::SessionStop) => break Ok(()),
            _ => Ok(()),
        };
        if let Err(e) = outcome {
            break Err(e);
        }
    };
    let _ = phone.stop();
    resultado
}

#[derive(Clone)]
pub struct PhoneAuth {
    pub identity: cdc_security::Identity,
    pub paired: Arc<Mutex<Vec<String>>>,
    pub confirm: Arc<dyn Fn(&str) -> bool + Send + Sync>,
}

impl PhoneAuth {
    pub fn new(
        identity: cdc_security::Identity,
        confirm: impl Fn(&str) -> bool + Send + Sync + 'static,
    ) -> Self {
        Self {
            identity,
            paired: Arc::default(),
            confirm: Arc::new(confirm),
        }
    }
}

pub fn accept_client(tcp: TcpStream, auth: &PhoneAuth) -> Result<Option<TcpStream>, SenderError> {
    let link = cdc_security::accept_secure(tcp, &auth.identity)
        .map_err(|e| SenderError::Io(io::Error::other(e.to_string())))?;
    let peer = link.peer_fingerprint.clone();
    let mut stream = link.stream;
    let known = auth
        .paired
        .lock()
        .map(|p| p.contains(&peer))
        .unwrap_or(false);
    if known {
        return Ok(Some(stream));
    }

    let write = |stream: &mut TcpStream, m: &Message| -> Result<(), SenderError> {
        m.to_frame(0)?.write_to(stream)?;
        stream.flush()?;
        Ok(())
    };
    write(
        &mut stream,
        &Message::Error {
            code: ErrorCode::AuthFailed,
            message: "pareamento necessário".into(),
        },
    )?;
    let nonce = loop {
        match Frame::read_from(&mut stream)? {
            None => return Ok(None),
            Some(f) if f.kind == FrameType::Control => {
                if let Ok(Message::PairRequest { nonce }) = Message::from_frame(&f) {
                    break nonce;
                }
            }
            Some(_) => {}
        }
    };
    let code = cdc_security::pairing_code(&auth.identity.fingerprint(), &peer, &nonce);
    let accepted = (auth.confirm)(&code);
    if !accepted {
        write(
            &mut stream,
            &Message::PairDenied {
                reason: "recusado no celular".into(),
            },
        )?;
        return Ok(None);
    }
    loop {
        match Frame::read_from(&mut stream)? {
            None => return Ok(None),
            Some(f) if f.kind == FrameType::Control => {
                if let Ok(Message::PairConfirm { confirmed, .. }) = Message::from_frame(&f) {
                    if !confirmed {
                        return Ok(None);
                    }
                    break;
                }
            }
            Some(_) => {}
        }
    }
    if let Ok(mut paired) = auth.paired.lock() {
        paired.push(peer);
    }
    write(
        &mut stream,
        &Message::PairConfirm {
            nonce,
            confirmed: true,
        },
    )?;
    Ok(Some(stream))
}
