//! A imagem do celular tem que chegar em pé. Estes testes usam o `ffmpeg` de verdade e são
//! pulados se ele não estiver instalado.

// Funções auxiliares de teste: falhar com panic é o comportamento desejado.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::net::TcpListener;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use cdc_core::{
    DISCARD, SessionEvent, SessionOptions, Sink, StopHandle, connect, run, video_filter,
};
use cdc_protocol::VideoProfile;
use cdc_testsender::{Options as SenderOptions, serve_connection};

fn ffmpeg_disponivel() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn ffmpeg(args: &[&str]) -> String {
    let saida = Command::new("ffmpeg")
        .args(["-hide_banner", "-y"])
        .args(args)
        .output()
        .expect("ffmpeg");
    String::from_utf8_lossy(&saida.stderr).into_owned()
}

/// Cena em pé com `w`×`h`, uma imagem assimétrica: com o padrão de teste, girar para o lado
/// errado ou de cabeça para baixo muda o resultado.
fn criar_cena(destino: &Path, w: u32, h: u32) {
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        &format!("testsrc2=size={w}x{h}:rate=1"),
        "-frames:v",
        "1",
        destino.to_str().unwrap(),
    ]);
}

/// O quadro como o sensor o entregaria: a cena girada `rotacao` graus ao contrário.
fn criar_sensor(cena: &Path, destino: &Path, rotacao: u32) {
    let filtro = match rotacao {
        90 => "transpose=2",
        180 => "transpose=1,transpose=1",
        270 => "transpose=1",
        _ => "null",
    };
    ffmpeg(&[
        "-i",
        cena.to_str().unwrap(),
        "-vf",
        filtro,
        "-frames:v",
        "1",
        destino.to_str().unwrap(),
    ]);
}

fn aplicar(sensor: &Path, destino: &Path, filtro: Option<String>) {
    let filtro = filtro.unwrap_or_else(|| "null".into());
    ffmpeg(&[
        "-i",
        sensor.to_str().unwrap(),
        "-vf",
        &filtro,
        "-frames:v",
        "1",
        destino.to_str().unwrap(),
    ]);
}

/// Similaridade estrutural (SSIM, de 0 a 1) entre duas imagens do mesmo tamanho.
fn ssim(a: &Path, b: &Path) -> f64 {
    let log = ffmpeg(&[
        "-i",
        a.to_str().unwrap(),
        "-i",
        b.to_str().unwrap(),
        "-lavfi",
        "ssim",
        "-f",
        "null",
        "-",
    ]);
    log.split("All:")
        .nth(1)
        .and_then(|t| t.split_whitespace().next())
        .and_then(|n| n.parse().ok())
        .unwrap_or_else(|| panic!("sem SSIM na saída do ffmpeg:\n{log}"))
}

#[test]
fn a_rotacao_anunciada_deixa_a_imagem_em_pe() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let dir = std::env::temp_dir().join(format!("cdc-orient-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // O sensor é sempre horizontal.
    let (sensor_w, sensor_h) = (640, 360);

    for rotacao in [0u32, 90, 180, 270] {
        let (cena_w, cena_h) = if rotacao % 180 == 90 {
            (sensor_h, sensor_w)
        } else {
            (sensor_w, sensor_h)
        };
        let cena = dir.join(format!("cena-{rotacao}.png"));
        let sensor = dir.join(format!("sensor-{rotacao}.png"));
        let certo = dir.join(format!("certo-{rotacao}.png"));
        let errado = dir.join(format!("errado-{rotacao}.png"));
        criar_cena(&cena, cena_w, cena_h);
        criar_sensor(&cena, &sensor, rotacao);

        aplicar(
            &sensor,
            &certo,
            video_filter(sensor_w, sensor_h, rotacao, cena_w, cena_h),
        );
        // Girar o oposto do certo tem que dar uma imagem claramente diferente: sem isto o
        // teste não provaria a direção.
        aplicar(
            &sensor,
            &errado,
            video_filter(sensor_w, sensor_h, (rotacao + 180) % 360, cena_w, cena_h),
        );

        let acerto = ssim(&certo, &cena);
        let erro = ssim(&errado, &cena);
        assert!(
            acerto > 0.97,
            "rotação {rotacao}°: SSIM {acerto} (esperava a cena em pé)"
        );
        assert!(
            erro < 0.9,
            "rotação {rotacao}°: o teste não distingue o lado errado (SSIM {erro})"
        );
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn imagem_em_pe_num_quadro_horizontal_ganha_barras_pretas_dos_lados() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let dir = std::env::temp_dir().join(format!("cdc-barras-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let cena = dir.join("cena.png");
    let sensor = dir.join("sensor.png");
    criar_cena(&cena, 360, 640);
    criar_sensor(&cena, &sensor, 90);

    // Cena em pé num quadro horizontal 640×360.
    let filtro = video_filter(640, 360, 90, 640, 360).expect("precisa de filtro");
    let bruto = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-i"])
        .arg(&sensor)
        .args([
            "-vf",
            &filtro,
            "-frames:v",
            "1",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ])
        .output()
        .expect("ffmpeg")
        .stdout;
    assert_eq!(
        bruto.len(),
        640 * 360,
        "o quadro de saída tem que ser 640×360"
    );

    let coluna_max = |x: usize| (0..360).map(|y| bruto[y * 640 + x]).max().unwrap();
    for x in (0..30).chain(610..640) {
        assert!(
            coluna_max(x) <= 24,
            "coluna {x} devia ser preta, mas tem {}",
            coluna_max(x)
        );
    }
    assert!(coluna_max(320) > 80, "o centro devia ter a imagem");
    let _ = std::fs::remove_dir_all(dir);
}

/// Sobe o emissor simulado numa porta livre e devolve o endereço.
fn emissor(opcoes: SenderOptions) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endereco = listener.local_addr().unwrap().to_string();
    let t = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let _ = serve_connection(stream, &opcoes);
    });
    (endereco, t)
}

#[test]
fn girar_o_celular_no_meio_da_sessao_reinicia_a_saida_com_a_nova_rotacao() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let mut opcoes = SenderOptions::new(VideoProfile::Hd, 6);
    opcoes.rotation = 0;
    opcoes.rotate_after = Some((3, 90));
    let (endereco, servidor) = emissor(opcoes);

    let sessao = SessionOptions {
        sink: Sink {
            v4l2: Some(DISCARD.into()),
            dump: None,
        },
        ..SessionOptions::default()
    };
    let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
    let mut eventos = Vec::new();
    let relatorio = run(stream, &sessao, &StopHandle::new(), |e| eventos.push(e)).unwrap();
    let _ = servidor.join();

    let perfis: Vec<u32> = eventos
        .iter()
        .filter_map(|e| match e {
            SessionEvent::Profile { rotation, .. } => Some(*rotation),
            _ => None,
        })
        .collect();
    assert_eq!(
        perfis,
        vec![0, 90],
        "o emissor anuncia a rotação duas vezes"
    );

    let saidas: Vec<(u32, u32, u32)> = eventos
        .iter()
        .filter_map(|e| match e {
            SessionEvent::Output {
                canvas_width,
                canvas_height,
                rotation,
                ..
            } => Some((*canvas_width, *canvas_height, *rotation)),
            _ => None,
        })
        .collect();
    // O quadro de saída não muda de tamanho, só a rotação aplicada.
    assert_eq!(saidas, vec![(1920, 1080, 0), (1920, 1080, 90)]);
    assert!(
        relatorio.video_frames > 150,
        "frames: {}",
        relatorio.video_frames
    );
}

#[test]
fn stop_encerra_a_sessao_sem_esperar_o_emissor() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let (endereco, servidor) = emissor(SenderOptions::new(VideoProfile::Hd, 30));
    let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
    let parar = StopHandle::new();
    let (tx, rx) = mpsc::channel();
    let parar2 = parar.clone();
    let sessao = thread::spawn(move || {
        let r = run(stream, &SessionOptions::default(), &parar2, |_| {});
        let _ = tx.send(Instant::now());
        r
    });

    thread::sleep(Duration::from_millis(1500));
    let pedido = Instant::now();
    parar.stop();
    let fim = rx
        .recv_timeout(Duration::from_secs(5))
        .expect("a sessão não terminou");
    assert!(fim.duration_since(pedido) < Duration::from_secs(2));
    assert!(sessao.join().unwrap().is_ok());
    drop(servidor);
}

#[test]
fn conectar_a_um_endereco_invalido_explica_o_erro() {
    let e = connect("isto nao e um endereco", Duration::from_millis(200)).unwrap_err();
    assert!(e.to_string().contains("endereço inválido"), "{e}");
    // Porta fechada: recusa na hora.
    let e = connect("127.0.0.1:1", Duration::from_millis(500)).unwrap_err();
    assert!(e.to_string().contains("não consegui conectar"), "{e}");
}

/// Lê as dimensões de um JPEG pelo ffprobe, que o decodifica de verdade.
fn dimensoes_jpeg(bytes: &[u8]) -> (u32, u32) {
    use std::io::Write;
    let mut filho = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0",
            "-f",
            "mjpeg",
            "-i",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    filho.stdin.take().unwrap().write_all(bytes).unwrap();
    let saida = filho.wait_with_output().unwrap();
    let texto = String::from_utf8_lossy(&saida.stdout).trim().to_string();
    let (w, h) = texto
        .split_once(',')
        .unwrap_or_else(|| panic!("ffprobe: {texto:?}"));
    (w.parse().unwrap(), h.parse().unwrap())
}

#[test]
fn a_previa_chega_como_jpeg_valido_ja_em_pe_e_no_formato_escolhido() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    for (canvas, esperado) in [
        (cdc_core::Canvas::Horizontal, (480, 270)),
        (cdc_core::Canvas::Vertical, (480, 854)),
    ] {
        let mut opcoes = SenderOptions::new(VideoProfile::Hd, 4);
        opcoes.rotation = 90; // celular em pé
        let (endereco, servidor) = emissor(opcoes);
        let sessao = SessionOptions {
            // Sem webcam virtual: só a prévia.
            sink: Sink::default(),
            preview: true,
            canvas,
            ..SessionOptions::default()
        };
        let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
        let mut quadros: Vec<Vec<u8>> = Vec::new();
        run(stream, &sessao, &StopHandle::new(), |e| {
            if let SessionEvent::Preview(j) = e {
                quadros.push(j);
            }
        })
        .unwrap();
        let _ = servidor.join();

        // 4 s a 10 por segundo; tolera o início e a fila que descarta quadros.
        assert!(
            quadros.len() >= 15,
            "{canvas:?}: só {} quadros de prévia",
            quadros.len()
        );
        for q in &quadros {
            assert!(q.starts_with(&[0xFF, 0xD8]) && q.ends_with(&[0xFF, 0xD9]));
        }
        assert_eq!(
            dimensoes_jpeg(&quadros[quadros.len() / 2]),
            esperado,
            "{canvas:?}"
        );
    }
}

/// Roda uma sessão curta e devolve as saídas de vídeo (largura, altura, rotação) anunciadas.
fn saidas_da_sessao(
    rotation: u32,
    rotate_after: Option<(u32, u32)>,
    canvas: cdc_core::Canvas,
) -> Vec<(u32, u32, u32)> {
    let mut opcoes = SenderOptions::new(VideoProfile::Hd, 6);
    opcoes.rotation = rotation;
    opcoes.rotate_after = rotate_after;
    let (endereco, servidor) = emissor(opcoes);
    let sessao = SessionOptions {
        sink: Sink {
            v4l2: Some(DISCARD.into()),
            dump: None,
        },
        canvas,
        ..SessionOptions::default()
    };
    let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
    let mut saidas = Vec::new();
    run(stream, &sessao, &StopHandle::new(), |e| {
        if let SessionEvent::Output {
            canvas_width,
            canvas_height,
            rotation,
            ..
        } = e
        {
            saidas.push((canvas_width, canvas_height, rotation));
        }
    })
    .unwrap();
    let _ = servidor.join();
    saidas
}

#[test]
fn o_formato_automatico_acompanha_a_posicao_do_celular_ao_conectar() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    use cdc_core::Canvas;
    // Em pé: saída vertical. Deitado: horizontal.
    assert_eq!(
        saidas_da_sessao(90, None, Canvas::Auto),
        vec![(1080, 1920, 90)]
    );
    assert_eq!(
        saidas_da_sessao(0, None, Canvas::Auto),
        vec![(1920, 1080, 0)]
    );
    // Formato escolhido à mão vale, seja qual for a posição.
    assert_eq!(
        saidas_da_sessao(90, None, Canvas::Horizontal),
        vec![(1920, 1080, 90)]
    );
    assert_eq!(
        saidas_da_sessao(0, None, Canvas::Vertical),
        vec![(1080, 1920, 0)]
    );
}

#[test]
fn o_formato_automatico_nao_muda_quando_o_celular_gira_no_meio_da_sessao() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    // Começa em pé (vertical) e é deitado: o tamanho da webcam virtual não pode mudar.
    let saidas = saidas_da_sessao(90, Some((3, 0)), cdc_core::Canvas::Auto);
    assert_eq!(saidas, vec![(1080, 1920, 90), (1080, 1920, 0)]);
}

#[test]
fn trocar_a_resolucao_do_celular_nao_muda_o_tamanho_da_saida() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    // É o que mantém o OBS feliz: a webcam virtual tem sempre o mesmo tamanho, seja o
    // celular HD, Full HD ou 2K.
    let mut tamanhos = Vec::new();
    for perfil in [VideoProfile::Hd, VideoProfile::FullHd, VideoProfile::Qhd] {
        let (endereco, servidor) = emissor(SenderOptions::new(perfil, 3));
        let sessao = SessionOptions {
            sink: Sink {
                v4l2: Some(DISCARD.into()),
                dump: None,
            },
            ..SessionOptions::default()
        };
        let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
        let mut saida = None;
        run(stream, &sessao, &StopHandle::new(), |e| {
            if let SessionEvent::Output {
                canvas_width,
                canvas_height,
                ..
            } = e
            {
                saida.get_or_insert((canvas_width, canvas_height));
            }
        })
        .unwrap();
        let _ = servidor.join();
        tamanhos.push(saida.expect("sem saída"));
    }
    assert_eq!(tamanhos, vec![(1920, 1080); 3]);
}

#[test]
fn o_tamanho_da_saida_pode_ser_escolhido() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    for (tamanho, esperado) in [
        (cdc_core::OutputSize::Hd, (1280, 720)),
        (cdc_core::OutputSize::Qhd, (2560, 1440)),
    ] {
        let (endereco, servidor) = emissor(SenderOptions::new(VideoProfile::FullHd, 3));
        let sessao = SessionOptions {
            sink: Sink {
                v4l2: Some(DISCARD.into()),
                dump: None,
            },
            output_size: tamanho,
            ..SessionOptions::default()
        };
        let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
        let mut saida = None;
        run(stream, &sessao, &StopHandle::new(), |e| {
            if let SessionEvent::Output {
                canvas_width,
                canvas_height,
                ..
            } = e
            {
                saida.get_or_insert((canvas_width, canvas_height));
            }
        })
        .unwrap();
        let _ = servidor.join();
        assert_eq!(saida, Some(esperado), "{tamanho:?}");
    }
}

/// Largura, altura e dispositivo de uma saída de vídeo.
type Saida = (u32, u32, Option<String>);

/// Roda uma sessão com dispositivos por tamanho e formato e devolve o primeiro evento de saída
/// e os avisos.
fn sessao_com_dispositivos(
    rotation: u32,
    tamanho: cdc_core::OutputSize,
    canvas: cdc_core::Canvas,
    dispositivos: Vec<cdc_core::ShapeDevice>,
) -> (Option<Saida>, Vec<String>) {
    let mut opcoes = SenderOptions::new(VideoProfile::Hd, 3);
    opcoes.rotation = rotation;
    let (endereco, servidor) = emissor(opcoes);
    let sessao = SessionOptions {
        output_size: tamanho,
        canvas,
        shape_devices: dispositivos,
        preview: true,
        ..SessionOptions::default()
    };
    let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
    let (mut saida, mut avisos) = (None, Vec::new());
    run(stream, &sessao, &StopHandle::new(), |e| match e {
        SessionEvent::Output {
            canvas_width,
            canvas_height,
            device,
            ..
        } => {
            saida.get_or_insert((canvas_width, canvas_height, device));
        }
        SessionEvent::Notice(n) => avisos.push(n),
        _ => {}
    })
    .unwrap();
    let _ = servidor.join();
    (saida, avisos)
}

fn familia() -> Vec<cdc_core::ShapeDevice> {
    use cdc_core::{Canvas, OutputSize, ShapeDevice};
    let mut v = Vec::new();
    for (tamanho, nome) in [
        (OutputSize::Hd, "hd"),
        (OutputSize::FullHd, "fullhd"),
        (OutputSize::Qhd, "qhd"),
    ] {
        for (canvas, orientacao) in [(Canvas::Horizontal, "h"), (Canvas::Vertical, "v")] {
            v.push(ShapeDevice {
                size: tamanho,
                canvas,
                path: format!("null:{nome}-{orientacao}"),
            });
        }
    }
    v
}

#[test]
fn cada_tamanho_e_formato_escreve_no_seu_proprio_dispositivo() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    use cdc_core::{Canvas, OutputSize};
    // Celular em pé, automático, Full HD: o dispositivo vertical de Full HD.
    let (saida, avisos) = sessao_com_dispositivos(90, OutputSize::FullHd, Canvas::Auto, familia());
    assert_eq!(saida, Some((1080, 1920, Some("null:fullhd-v".into()))));
    assert!(avisos.is_empty(), "{avisos:?}");
    // Deitado, 2K: o horizontal de 2K.
    let (saida, _) = sessao_com_dispositivos(0, OutputSize::Qhd, Canvas::Auto, familia());
    assert_eq!(saida, Some((2560, 1440, Some("null:qhd-h".into()))));
    // Formato escolhido à mão, HD: vertical de HD, mesmo com o celular deitado.
    let (saida, _) = sessao_com_dispositivos(0, OutputSize::Hd, Canvas::Vertical, familia());
    assert_eq!(saida, Some((720, 1280, Some("null:hd-v".into()))));
}

#[test]
fn o_tamanho_de_cada_dispositivo_nunca_depende_da_resolucao_do_celular() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    use cdc_core::{Canvas, OutputSize};
    // O mesmo dispositivo recebe sempre o mesmo tamanho, seja qual for o celular.
    for perfil in [VideoProfile::Hd, VideoProfile::FullHd, VideoProfile::Qhd] {
        let (endereco, servidor) = emissor(SenderOptions::new(perfil, 3));
        let sessao = SessionOptions {
            output_size: OutputSize::FullHd,
            canvas: Canvas::Horizontal,
            shape_devices: familia(),
            ..SessionOptions::default()
        };
        let stream = connect(&endereco, Duration::from_secs(5)).unwrap();
        let mut saida = None;
        run(stream, &sessao, &StopHandle::new(), |e| {
            if let SessionEvent::Output {
                canvas_width,
                canvas_height,
                device,
                ..
            } = e
            {
                saida.get_or_insert((canvas_width, canvas_height, device));
            }
        })
        .unwrap();
        let _ = servidor.join();
        assert_eq!(
            saida,
            Some((1920, 1080, Some("null:fullhd-h".into()))),
            "{perfil:?}"
        );
    }
}

#[test]
fn sem_o_dispositivo_do_par_avisa_e_ainda_mostra_a_previa() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    use cdc_core::{Canvas, OutputSize, ShapeDevice};
    // Só existe o horizontal de Full HD; o celular está em pé.
    let so_um = vec![ShapeDevice {
        size: OutputSize::FullHd,
        canvas: Canvas::Horizontal,
        path: "null:fullhd-h".into(),
    }];
    let (saida, avisos) = sessao_com_dispositivos(90, OutputSize::FullHd, Canvas::Auto, so_um);
    assert_eq!(
        saida,
        Some((1080, 1920, None)),
        "sem dispositivo, sem escrita"
    );
    assert!(
        avisos.iter().any(|a| a.contains("linux-webcam-virtual.sh")),
        "{avisos:?}"
    );
}
