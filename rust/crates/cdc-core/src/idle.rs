use std::io::Write;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::output::{DISCARD, OutputError};

const FPS: u32 = 5;

pub struct IdleFeed {
    stop: Arc<AtomicBool>,
    writer: Option<JoinHandle<()>>,
    child: Child,
}

pub fn black_frame(width: u32, height: u32) -> Vec<u8> {
    [16u8, 128, 16, 128].repeat((width as usize * height as usize) / 2)
}

impl IdleFeed {
    pub fn start(ffmpeg: &str, device: &str, width: u32, height: u32) -> Result<Self, OutputError> {
        let size = format!("{width}x{height}");
        let rate = FPS.to_string();
        let mut cmd = Command::new(ffmpeg);
        cmd.args(["-hide_banner", "-loglevel", "error"])
            .args([
                "-f", "rawvideo", "-pix_fmt", "yuyv422", "-s", &size, "-r", &rate,
            ])
            .args(["-i", "pipe:0"]);
        if device.starts_with(DISCARD) {
            cmd.args(["-c:v", "rawvideo", "-f", "null", "-"]);
        } else {
            cmd.args([
                "-c:v", "rawvideo", "-pix_fmt", "yuyv422", "-f", "v4l2", device,
            ]);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(OutputError::Spawn)?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| OutputError::Died("sem entrada para o ffmpeg".into()))?;
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let frame = black_frame(width, height);
        let writer = thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                if stdin.write_all(&frame).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(u64::from(1000 / FPS)));
            }
        });
        Ok(Self {
            stop,
            writer: Some(writer),
            child,
        })
    }

    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        for _ in 0..20 {
            if !matches!(self.child.try_wait(), Ok(None)) {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for IdleFeed {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quadro_preto_tem_o_tamanho_de_um_quadro_yuyv() {
        let quadro = black_frame(1920, 1080);
        assert_eq!(quadro.len(), 1920 * 1080 * 2);
        assert_eq!(&quadro[..4], &[16, 128, 16, 128]);
    }
}
