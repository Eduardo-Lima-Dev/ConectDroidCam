use std::collections::VecDeque;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use thiserror::Error;

pub const DISCARD: &str = "null";

#[derive(Debug, Clone, Default)]
pub struct Sink {
    pub v4l2: Option<String>,
    pub dump: Option<String>,
}

#[derive(Debug, Error)]
pub enum OutputError {
    #[error("não consegui iniciar o ffmpeg ({0}). Ele está instalado?")]
    Spawn(io::Error),
    #[error("o ffmpeg parou ao escrever na webcam virtual: {0}")]
    Died(String),
    #[error(transparent)]
    Io(#[from] io::Error),
}

type Log = Arc<Mutex<VecDeque<String>>>;

struct Running {
    child: Child,
    stdin: Option<ChildStdin>,
    log: Log,
}

impl Running {
    fn last_lines(&self) -> String {
        let log = self.log.lock().map(|l| l.clone()).unwrap_or_default();
        let linhas: Vec<&str> = log.iter().map(String::as_str).collect();
        if linhas.is_empty() {
            "sem detalhes do ffmpeg (rode com CDC_FFMPEG_LOGLEVEL=info)".into()
        } else {
            linhas.join(" | ")
        }
    }

    fn finish(mut self) {
        drop(self.stdin.take());
        let limite = Instant::now() + Duration::from_secs(2);
        while Instant::now() < limite {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

const PREVIEW_WIDTH: u32 = 480;
const PREVIEW_FPS: u32 = 10;

pub(crate) struct Output {
    ffmpeg: String,
    device: Option<String>,
    dump: Option<File>,
    running: Option<Running>,
    filter: Option<Option<String>>,
    preview: bool,
    preview_tx: SyncSender<Vec<u8>>,
    preview_rx: Receiver<Vec<u8>>,
}

#[derive(Default)]
pub(crate) struct JpegSplitter {
    buf: Vec<u8>,
}

const MAX_JPEG_BUFFER: usize = 8 * 1024 * 1024;

impl JpegSplitter {
    pub(crate) fn push(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buf.extend_from_slice(data);
        let mut frames = Vec::new();
        loop {
            let Some(start) = self.buf.windows(2).position(|w| w == [0xFF, 0xD8]) else {
                let keep = usize::from(self.buf.last() == Some(&0xFF));
                self.buf.drain(..self.buf.len() - keep);
                break;
            };
            let Some(end) = self.buf[start + 2..]
                .windows(2)
                .position(|w| w == [0xFF, 0xD9])
            else {
                self.buf.drain(..start);
                if self.buf.len() > MAX_JPEG_BUFFER {
                    self.buf.clear();
                }
                break;
            };
            let end = start + 2 + end + 2;
            frames.push(self.buf[start..end].to_vec());
            self.buf.drain(..end);
        }
        frames
    }
}

impl Output {
    pub(crate) fn new(sink: &Sink, ffmpeg: &str, preview: bool) -> Result<Self, OutputError> {
        let (preview_tx, preview_rx) = mpsc::sync_channel(2);
        Ok(Self {
            ffmpeg: ffmpeg.to_string(),
            device: sink.v4l2.clone(),
            dump: sink.dump.as_ref().map(File::create).transpose()?,
            running: None,
            filter: None,
            preview,
            preview_tx,
            preview_rx,
        })
    }

    pub(crate) fn set_device(&mut self, device: Option<String>) {
        self.device = device;
    }

    pub(crate) fn next_preview(&self) -> Option<Vec<u8>> {
        self.preview_rx.try_recv().ok()
    }

    pub(crate) fn has_process(&self) -> bool {
        self.running.is_some()
    }

    pub(crate) fn is_running_with(&self, filter: &Option<String>) -> bool {
        self.running.is_some() && self.filter.as_ref() == Some(filter)
    }

    pub(crate) fn start(&mut self, filter: Option<String>) -> Result<(), OutputError> {
        let device = self.device.clone();
        if device.is_none() && !self.preview {
            return Ok(());
        }
        if let Some(antigo) = self.running.take() {
            antigo.finish();
        }
        let loglevel = std::env::var("CDC_FFMPEG_LOGLEVEL").unwrap_or_else(|_| "error".into());
        let mut cmd = Command::new(&self.ffmpeg);
        cmd.args(["-hide_banner", "-loglevel", &loglevel])
            .args(["-flags", "low_delay"])
            .args(["-probesize", "100000", "-analyzeduration", "0"])
            .args(["-f", "h264", "-framerate", "30", "-i", "pipe:0"]);
        let base = filter.clone().unwrap_or_else(|| "null".into());
        let reduzir = format!("fps={PREVIEW_FPS},scale={PREVIEW_WIDTH}:-2");
        let grafo = match (&device, self.preview) {
            (Some(_), true) => format!("[0:v]{base},split=2[a][b];[b]{reduzir}[p]"),
            (Some(_), false) => format!("[0:v]{base}[a]"),
            (None, _) => format!("[0:v]{base},{reduzir}[p]"),
        };
        cmd.args(["-filter_complex", &grafo]);
        match device.as_deref() {
            Some(d) if d.starts_with(DISCARD) => {
                cmd.args(["-map", "[a]", "-f", "null", "-"]);
            }
            Some(dispositivo) => {
                cmd.args([
                    "-map",
                    "[a]",
                    "-pix_fmt",
                    "yuyv422",
                    "-f",
                    "v4l2",
                    dispositivo,
                ]);
            }
            None => {}
        }
        if self.preview {
            cmd.args([
                "-map", "[p]", "-c:v", "mjpeg", "-q:v", "7", "-pix_fmt", "yuvj420p",
            ])
            .args(["-f", "image2pipe", "pipe:1"])
            .stdout(Stdio::piped());
        }
        cmd.stdin(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(OutputError::Spawn)?;
        let stdin = child.stdin.take();
        if let Some(mut stdout) = child.stdout.take() {
            let tx = self.preview_tx.clone();
            thread::spawn(move || {
                let mut splitter = JpegSplitter::default();
                let mut chunk = vec![0u8; 64 * 1024];
                while let Ok(n) = stdout.read(&mut chunk) {
                    if n == 0 {
                        break;
                    }
                    for quadro in splitter.push(&chunk[..n]) {
                        let _ = tx.try_send(quadro);
                    }
                }
            });
        }
        let log: Log = Arc::default();
        if let Some(stderr) = child.stderr.take() {
            let log = Arc::clone(&log);
            thread::spawn(move || {
                for linha in BufReader::new(stderr).lines().map_while(Result::ok) {
                    if std::env::var_os("CDC_FFMPEG_LOGLEVEL").is_some() {
                        eprintln!("[ffmpeg] {linha}");
                    }
                    if let Ok(mut l) = log.lock() {
                        if l.len() == 6 {
                            l.pop_front();
                        }
                        l.push_back(linha);
                    }
                }
            });
        }
        self.running = Some(Running { child, stdin, log });
        self.filter = Some(filter);
        Ok(())
    }

    pub(crate) fn write(&mut self, data: &[u8]) -> Result<(), OutputError> {
        if let Some(r) = &mut self.running
            && let Some(stdin) = &mut r.stdin
            && let Err(e) = stdin.write_all(data)
        {
            return Err(if e.kind() == io::ErrorKind::BrokenPipe {
                OutputError::Died(r.last_lines())
            } else {
                e.into()
            });
        }
        if let Some(file) = &mut self.dump {
            file.write_all(data)?;
        }
        Ok(())
    }

    pub(crate) fn finish(&mut self) {
        if let Some(r) = self.running.take() {
            r.finish();
        }
    }
}

impl Drop for Output {
    fn drop(&mut self) {
        self.finish();
    }
}

#[cfg(test)]
mod tests {
    use super::JpegSplitter;

    fn quadro(miolo: &[u8]) -> Vec<u8> {
        let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0];
        v.extend_from_slice(miolo);
        v.extend_from_slice(&[0xFF, 0xD9]);
        v
    }

    #[test]
    fn separa_jpegs_concatenados() {
        let (a, b) = (quadro(&[1, 2, 3]), quadro(&[9; 50]));
        let mut s = JpegSplitter::default();
        let quadros = s.push(&[a.clone(), b.clone()].concat());
        assert_eq!(quadros, vec![a, b]);
    }

    #[test]
    fn funciona_com_bytes_chegando_aos_pedacos_inclusive_no_meio_dos_marcadores() {
        let (a, b) = (quadro(&[7; 20]), quadro(&[8; 20]));
        let fluxo = [a.clone(), b.clone()].concat();
        let mut s = JpegSplitter::default();
        let mut obtidos = Vec::new();
        for pedaco in fluxo.chunks(1) {
            obtidos.extend(s.push(pedaco));
        }
        assert_eq!(obtidos, vec![a, b]);
    }

    #[test]
    fn lixo_antes_do_primeiro_quadro_e_ignorado() {
        let a = quadro(&[5; 10]);
        let mut s = JpegSplitter::default();
        let quadros = s.push(&[vec![0, 1, 2, 0xFF], a.clone()].concat());
        assert_eq!(quadros, vec![a]);
    }

    #[test]
    fn quadro_incompleto_espera_o_resto() {
        let a = quadro(&[3; 30]);
        let mut s = JpegSplitter::default();
        assert!(s.push(&a[..10]).is_empty());
        assert_eq!(s.push(&a[10..]), vec![a]);
    }

    #[test]
    fn entrada_sem_quadros_nao_cresce_sem_limite() {
        let mut s = JpegSplitter::default();
        for _ in 0..5 {
            assert!(s.push(&vec![0xAA; 1024 * 1024]).is_empty());
        }
        assert!(s.buf.len() <= 1);
    }
}
