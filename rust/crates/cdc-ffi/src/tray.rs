use std::sync::Mutex;

use ksni::blocking::{Handle, TrayMethods};
use ksni::menu::{MenuItem, StandardItem};

use crate::api::{TrayAction, TrayEvent, TrayStatus};
use crate::frb_generated::StreamSink;

struct CdcTray {
    sink: StreamSink<TrayEvent>,
    icon: ksni::Icon,
    status: TrayStatus,
}

impl CdcTray {
    fn send(&self, action: TrayAction) {
        let _ = self.sink.add(TrayEvent {
            action,
            text: String::new(),
        });
    }
}

fn item(label: &str, enabled: bool, action: TrayAction) -> MenuItem<CdcTray> {
    StandardItem {
        label: label.into(),
        enabled,
        activate: Box::new(move |tray: &mut CdcTray| tray.send(action)),
        ..Default::default()
    }
    .into()
}

impl ksni::Tray for CdcTray {
    fn id(&self) -> String {
        "conectdroidcam".into()
    }

    fn title(&self) -> String {
        "ConectDroidCam".into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        vec![self.icon.clone()]
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "ConectDroidCam".into(),
            description: self.status.tooltip.clone(),
            ..Default::default()
        }
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        self.send(TrayAction::ShowWindow);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let s = &self.status;
        vec![
            StandardItem {
                label: s.status_line.clone(),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            item("Mostrar a janela", true, TrayAction::ShowWindow),
            item(
                if s.streaming {
                    "Parar a transmissão"
                } else {
                    "Iniciar a transmissão"
                },
                s.can_stream,
                TrayAction::ToggleStream,
            ),
            item("Trocar de câmera", s.can_switch, TrayAction::SwitchCamera),
            item("Desconectar", s.connected, TrayAction::Disconnect),
            MenuItem::Separator,
            item("Sair", true, TrayAction::Quit),
        ]
    }
}

static TRAY: Mutex<Option<Handle<CdcTray>>> = Mutex::new(None);

fn argb(rgba: &[u8]) -> Vec<u8> {
    rgba.as_chunks::<4>()
        .0
        .iter()
        .flat_map(|&[r, g, b, a]| [a, r, g, b])
        .collect()
}

pub fn start(
    icon_rgba: Vec<u8>,
    width: u32,
    height: u32,
    sandboxed: bool,
    sink: StreamSink<TrayEvent>,
) {
    stop();
    let tray = CdcTray {
        sink: sink.clone(),
        icon: ksni::Icon {
            width: width as i32,
            height: height as i32,
            data: argb(&icon_rgba),
        },
        status: TrayStatus {
            tooltip: String::new(),
            status_line: "Nenhum celular conectado".into(),
            connected: false,
            streaming: false,
            can_stream: false,
            can_switch: false,
        },
    };
    let event = match tray.disable_dbus_name(sandboxed).spawn() {
        Ok(handle) => {
            if let Ok(mut guard) = TRAY.lock() {
                *guard = Some(handle);
            }
            TrayEvent {
                action: TrayAction::Ready,
                text: String::new(),
            }
        }
        Err(e) => TrayEvent {
            action: TrayAction::Unavailable,
            text: e.to_string(),
        },
    };
    let _ = sink.add(event);
}

pub fn update(status: TrayStatus) {
    let handle = TRAY.lock().ok().and_then(|g| g.clone());
    if let Some(handle) = handle {
        let _ = handle.update(move |tray| tray.status = status);
    }
}

pub fn stop() {
    let handle = TRAY.lock().ok().and_then(|mut g| g.take());
    if let Some(handle) = handle {
        handle.shutdown().wait();
    }
}

#[cfg(test)]
mod tests {
    use super::argb;

    #[test]
    fn rgba_vira_argb() {
        assert_eq!(
            argb(&[1, 2, 3, 4, 5, 6, 7, 8]),
            vec![4, 1, 2, 3, 8, 5, 6, 7]
        );
    }
}
