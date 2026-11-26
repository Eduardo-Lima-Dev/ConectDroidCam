use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use cdc_core::{
    Canvas, Device, DeviceEvent, Discovery, OutputSize as CoreSize, SessionEvent, SessionOptions,
    Sink, StopHandle,
};

use cdc_protocol::{Facing, Message};

use crate::frb_generated::StreamSink;

#[derive(Clone)]
pub struct PhoneInfo {
    pub id: String,
    pub name: String,
    pub host: String,
    pub address: Option<String>,
    pub port: u16,
    pub lost: bool,
    pub error: Option<String>,
}

impl PhoneInfo {
    fn failure(message: String) -> Self {
        PhoneInfo {
            id: String::new(),
            name: String::new(),
            host: String::new(),
            address: None,
            port: 0,
            lost: false,
            error: Some(message),
        }
    }
}

impl From<Device> for PhoneInfo {
    fn from(d: Device) -> Self {
        PhoneInfo {
            address: d.address(),
            id: d.id,
            name: d.name,
            host: d.host,
            port: d.port,
            lost: false,
            error: None,
        }
    }
}

static DISCOVERY: Mutex<Option<Discovery>> = Mutex::new(None);

pub fn start_discovery(updates: StreamSink<PhoneInfo>) {
    stop_discovery();
    let for_events = updates.clone();
    let started = Discovery::start(move |evento| {
        let info = match evento {
            DeviceEvent::Found(d) => d.into(),
            DeviceEvent::Lost { id } => PhoneInfo {
                id,
                name: String::new(),
                host: String::new(),
                address: None,
                port: 0,
                lost: true,
                error: None,
            },
        };
        let _ = for_events.add(info);
    });
    match started {
        Ok(discovery) => {
            if let Ok(mut guard) = DISCOVERY.lock() {
                *guard = Some(discovery);
            }
        }
        Err(e) => {
            let _ = updates.add(PhoneInfo::failure(e.to_string()));
        }
    }
}

pub fn stop_discovery() {
    if let Ok(mut guard) = DISCOVERY.lock() {
        *guard = None;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiverEventKind {
    Hello,
    Profile,
    Output,
    Stats,
    Preview,
    Capabilities,
    PairingCode,
    Paired,
    PairingDenied,
    SenderError,
    Notice,
    Ended,
    Failed,
    PhoneIdentity,
}

#[derive(Debug, Clone)]
pub struct PhoneMode {
    pub width: u32,
    pub height: u32,
    pub available: bool,
    pub max_fps: u32,
    pub reason: String,
}

pub struct ReceiverEvent {
    pub kind: ReceiverEventKind,
    pub text: String,
    pub text2: String,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate_kbps: u32,
    pub rotation: u32,
    pub canvas_width: u32,
    pub canvas_height: u32,
    pub stats_fps: f64,
    pub stats_kbps: f64,
    pub stats_delay_ms: f64,
    pub frames: u64,
    pub preview: Vec<u8>,
    pub modes: Vec<PhoneMode>,
    pub fps_options: Vec<u32>,
    pub streaming: bool,
    pub front: bool,
    pub can_switch: bool,
}

impl ReceiverEvent {
    fn new(kind: ReceiverEventKind) -> Self {
        Self {
            kind,
            text: String::new(),
            text2: String::new(),
            width: 0,
            height: 0,
            fps: 0,
            bitrate_kbps: 0,
            rotation: 0,
            canvas_width: 0,
            canvas_height: 0,
            stats_fps: 0.0,
            stats_kbps: 0.0,
            stats_delay_ms: 0.0,
            frames: 0,
            preview: Vec::new(),
            modes: Vec::new(),
            fps_options: Vec::new(),
            streaming: false,
            front: false,
            can_switch: false,
        }
    }
}

impl From<SessionEvent> for ReceiverEvent {
    fn from(e: SessionEvent) -> Self {
        match e {
            SessionEvent::Hello {
                device_name,
                platform,
            } => Self {
                text: device_name,
                text2: platform,
                ..Self::new(ReceiverEventKind::Hello)
            },
            SessionEvent::Profile {
                width,
                height,
                fps,
                bitrate_kbps,
                rotation,
            } => Self {
                width,
                height,
                fps,
                bitrate_kbps,
                rotation,
                ..Self::new(ReceiverEventKind::Profile)
            },
            SessionEvent::Output {
                canvas_width,
                canvas_height,
                rotation,
                device,
            } => Self {
                canvas_width,
                canvas_height,
                rotation,
                text: device.unwrap_or_default(),
                ..Self::new(ReceiverEventKind::Output)
            },
            SessionEvent::Stats(s) => Self {
                stats_fps: s.fps,
                stats_kbps: s.kbps,
                stats_delay_ms: s.delay_ms,
                frames: s.frames,
                ..Self::new(ReceiverEventKind::Stats)
            },
            SessionEvent::Preview(jpeg) => Self {
                preview: jpeg,
                ..Self::new(ReceiverEventKind::Preview)
            },
            SessionEvent::Capabilities {
                modes,
                fps_options,
                front,
                can_switch,
                streaming,
            } => Self {
                modes: modes
                    .into_iter()
                    .map(|m| PhoneMode {
                        width: m.width,
                        height: m.height,
                        available: m.available,
                        max_fps: m.max_fps,
                        reason: m.reason.unwrap_or_default(),
                    })
                    .collect(),
                fps_options,
                front,
                can_switch,
                streaming,
                ..Self::new(ReceiverEventKind::Capabilities)
            },
            SessionEvent::PairingCode {
                code,
                phone_fingerprint,
            } => Self {
                text: code,
                text2: phone_fingerprint,
                ..Self::new(ReceiverEventKind::PairingCode)
            },
            SessionEvent::Paired { phone_fingerprint } => Self {
                text: phone_fingerprint,
                ..Self::new(ReceiverEventKind::Paired)
            },
            SessionEvent::PairingDenied { reason } => Self {
                text: reason,
                ..Self::new(ReceiverEventKind::PairingDenied)
            },
            SessionEvent::SenderError { code, message } => Self {
                text: code,
                text2: message,
                ..Self::new(ReceiverEventKind::SenderError)
            },
            SessionEvent::Notice(texto) => Self {
                text: texto,
                ..Self::new(ReceiverEventKind::Notice)
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Auto,
    Horizontal,
    Vertical,
}

impl From<OutputFormat> for Canvas {
    fn from(f: OutputFormat) -> Self {
        match f {
            OutputFormat::Auto => Canvas::Auto,
            OutputFormat::Horizontal => Canvas::Horizontal,
            OutputFormat::Vertical => Canvas::Vertical,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputSize {
    Hd,
    FullHd,
    Qhd,
}

impl From<OutputSize> for CoreSize {
    fn from(s: OutputSize) -> Self {
        match s {
            OutputSize::Hd => CoreSize::Hd,
            OutputSize::FullHd => CoreSize::FullHd,
            OutputSize::Qhd => CoreSize::Qhd,
        }
    }
}

pub struct ShapeDevice {
    pub size: OutputSize,
    pub vertical: bool,
    pub path: String,
}

static SESSION: Mutex<Option<StopHandle>> = Mutex::new(None);

#[allow(clippy::too_many_arguments)]
pub fn connect_phone(
    address: String,
    v4l2_device: Option<String>,
    format: OutputFormat,
    size: OutputSize,
    shape_devices: Vec<ShapeDevice>,
    preview: bool,
    pinned_fingerprint: Option<String>,
    events: StreamSink<ReceiverEvent>,
) {
    let fail = |text: String| {
        let _ = events.add(ReceiverEvent {
            text,
            ..ReceiverEvent::new(ReceiverEventKind::Failed)
        });
    };
    let stop = StopHandle::new();
    match SESSION.lock() {
        Ok(mut guard) => {
            if guard.as_ref().is_some_and(|s| !s.is_stopped()) {
                return fail("já existe uma sessão em andamento".into());
            }
            *guard = Some(stop.clone());
        }
        Err(_) => return fail("estado interno corrompido".into()),
    }
    let identity = match load_identity() {
        Ok(i) => i,
        Err(e) => {
            clear_session(&stop);
            return fail(e);
        }
    };
    let link = match cdc_core::connect_secure_phone(
        &address,
        Duration::from_secs(5),
        &identity,
        pinned_fingerprint.as_deref(),
    ) {
        Ok(l) => l,
        Err(e) => {
            clear_session(&stop);
            return fail(e.to_string());
        }
    };
    let _ = events.add(ReceiverEvent {
        text: link.peer_fingerprint.clone(),
        ..ReceiverEvent::new(ReceiverEventKind::PhoneIdentity)
    });
    let stream = link.stream;
    let options = SessionOptions {
        sink: Sink {
            v4l2: v4l2_device,
            dump: None,
        },
        canvas: format.into(),
        output_size: size.into(),
        shape_devices: shape_devices
            .into_iter()
            .map(|d| cdc_core::ShapeDevice {
                size: d.size.into(),
                canvas: if d.vertical {
                    Canvas::Vertical
                } else {
                    Canvas::Horizontal
                },
                path: d.path,
            })
            .collect(),
        device_name: computer_name(),
        own_fingerprint: identity.fingerprint(),
        phone_fingerprint: link.peer_fingerprint,
        preview,
        ..SessionOptions::default()
    };
    thread::spawn(move || {
        let resultado = cdc_core::run(stream, &options, &stop, |e| {
            let _ = events.add(e.into());
        });
        let final_event = match resultado {
            Ok(_) => ReceiverEvent::new(ReceiverEventKind::Ended),
            Err(e) => ReceiverEvent {
                text: e.to_string(),
                ..ReceiverEvent::new(ReceiverEventKind::Failed)
            },
        };
        let _ = events.add(final_event);
        clear_session(&stop);
    });
}

fn load_identity() -> Result<cdc_core::Identity, String> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::Path::new(&h).join(".config")))
        .unwrap_or_else(std::env::temp_dir);
    cdc_core::Identity::load_or_create(&base.join("conectdroidcam").join("identidade"))
        .map_err(|e| e.to_string())
}

fn clear_session(stop: &StopHandle) {
    if let Ok(mut guard) = SESSION.lock() {
        *guard = None;
    }
    stop.stop();
}

pub fn disconnect_phone() {
    if let Ok(guard) = SESSION.lock()
        && let Some(stop) = guard.as_ref()
    {
        stop.stop();
    }
}

fn command(message: Message) -> Option<String> {
    let guard = SESSION.lock().ok()?;
    match guard.as_ref() {
        Some(stop) if !stop.is_stopped() => stop.send(&message).err().map(|e| e.to_string()),
        _ => Some("não há conexão com o celular".into()),
    }
}

pub fn confirm_pairing(accept: bool) -> Option<String> {
    let guard = SESSION.lock().ok()?;
    match guard.as_ref() {
        Some(stop) if !stop.is_stopped() => {
            stop.confirm_pairing(accept).err().map(|e| e.to_string())
        }
        _ => Some("não há conexão com o celular".into()),
    }
}

pub fn phone_start_stream(width: u32, height: u32, fps: u32) -> Option<String> {
    command(Message::StreamStart { width, height, fps })
}

pub fn phone_stop_stream() -> Option<String> {
    command(Message::StreamStop)
}

pub fn phone_set_fps(fps: u32) -> Option<String> {
    command(Message::FpsSet { fps })
}

pub fn phone_switch_camera(front: Option<bool>) -> Option<String> {
    command(Message::CameraSwitch {
        facing: front.map(|f| if f { Facing::Front } else { Facing::Back }),
    })
}

static IDLE: Mutex<Option<cdc_core::IdleFeed>> = Mutex::new(None);

pub fn start_idle_feed(device: String, width: u32, height: u32) -> Option<String> {
    stop_idle_feed();
    match cdc_core::IdleFeed::start("ffmpeg", &device, width, height) {
        Ok(feed) => {
            if let Ok(mut guard) = IDLE.lock() {
                *guard = Some(feed);
            }
            None
        }
        Err(e) => Some(e.to_string()),
    }
}

pub fn stop_idle_feed() {
    let feed = IDLE.lock().ok().and_then(|mut guard| guard.take());
    if let Some(feed) = feed {
        feed.stop();
    }
}

pub fn ffmpeg_available() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

pub fn computer_name() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "computador".into())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayAction {
    Ready,
    Unavailable,
    ShowWindow,
    ToggleStream,
    SwitchCamera,
    Disconnect,
    Quit,
}

#[derive(Debug, Clone)]
pub struct TrayEvent {
    pub action: TrayAction,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct TrayStatus {
    pub tooltip: String,
    pub status_line: String,
    pub connected: bool,
    pub streaming: bool,
    pub can_stream: bool,
    pub can_switch: bool,
}

pub fn tray_start(
    icon_rgba: Vec<u8>,
    width: u32,
    height: u32,
    sandboxed: bool,
    events: StreamSink<TrayEvent>,
) {
    #[cfg(target_os = "linux")]
    crate::tray::start(icon_rgba, width, height, sandboxed, events);
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (icon_rgba, width, height, sandboxed);
        let _ = events.add(TrayEvent {
            action: TrayAction::Unavailable,
            text: "bandeja só existe no Linux".into(),
        });
    }
}

pub fn tray_update(status: TrayStatus) {
    #[cfg(target_os = "linux")]
    crate::tray::update(status);
    #[cfg(not(target_os = "linux"))]
    let _ = status;
}

pub fn tray_stop() {
    #[cfg(target_os = "linux")]
    crate::tray::stop();
}
