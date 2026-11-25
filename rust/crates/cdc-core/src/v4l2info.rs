use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

pub fn current_size(device: &str) -> Option<(u32, u32)> {
    let saida = Command::new("v4l2-ctl")
        .args(["-d", device, "--get-fmt-video"])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    parse_size(&String::from_utf8_lossy(&saida.stdout))
}

pub(crate) fn parse_size(texto: &str) -> Option<(u32, u32)> {
    let linha = texto.lines().find(|l| l.contains("Width/Height"))?;
    let (w, h) = linha.split_once(':')?.1.trim().split_once('/')?;
    Some((w.trim().parse().ok()?, h.trim().parse().ok()?))
}

pub fn other_openers(path: &str, own_pid: u32) -> Vec<String> {
    let Ok(procs) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    let alvo = Path::new(path);
    let mut nomes: Vec<String> = Vec::new();
    for entrada in procs.flatten() {
        let Some(pid) = entrada
            .file_name()
            .to_str()
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        if pid == own_pid || parent_of(pid) == Some(own_pid) {
            continue;
        }
        let Ok(fds) = fs::read_dir(entrada.path().join("fd")) else {
            continue;
        };
        let abre = fds
            .flatten()
            .any(|fd| fs::read_link(fd.path()).is_ok_and(|l| l == alvo));
        if abre {
            let nome = fs::read_to_string(entrada.path().join("comm"))
                .map(|c| c.trim().to_string())
                .unwrap_or_else(|_| pid.to_string());
            if !nomes.contains(&nome) {
                nomes.push(nome);
            }
        }
    }
    nomes
}

fn parent_of(pid: u32) -> Option<u32> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let depois = stat.rsplit_once(')')?.1;
    depois.split_whitespace().nth(1)?.parse().ok()
}

pub fn size_conflict_notice(device: &str, new_size: (u32, u32), own_pid: u32) -> Option<String> {
    let atual = current_size(device)?;
    if atual == new_size {
        return None;
    }
    let outros = other_openers(device, own_pid);
    if outros.is_empty() {
        return None;
    }
    Some(format!(
        "{} já está com a webcam virtual aberta em {}×{}, e a imagem agora tem {}×{}. \\
         Esconda e mostre a fonte de vídeo nesse programa (ou abra-o de novo) para ele usar o \\
         novo tamanho; até lá a imagem aparece embaralhada.",
        outros.join(", "),
        atual.0,
        atual.1,
        new_size.0,
        new_size.1
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_a_resolucao_da_saida_do_v4l2_ctl() {
        let saida = "Format Video Capture:\n\tWidth/Height      : 1920/1080\n\tPixel Format      : 'YUYV'\n";
        assert_eq!(parse_size(saida), Some((1920, 1080)));
    }

    #[test]
    fn saida_sem_resolucao_nao_da_nada() {
        assert_eq!(parse_size("erro qualquer"), None);
        assert_eq!(parse_size("Width/Height : abc/def"), None);
        assert_eq!(parse_size(""), None);
    }

    #[test]
    fn acha_quem_tem_um_arquivo_aberto_e_ignora_o_proprio_processo() {
        let caminho = std::env::temp_dir().join(format!("cdc-aberto-{}", std::process::id()));
        fs::write(&caminho, b"x").unwrap();
        let caminho_str = caminho.to_str().unwrap().to_string();

        let mut filho = Command::new("sh")
            .args(["-c", &format!("exec 3<'{caminho_str}'; exec sleep 5")])
            .spawn()
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(400));

        assert!(other_openers(&caminho_str, 1).contains(&"sleep".to_string()));
        assert!(!other_openers(&caminho_str, std::process::id()).contains(&"sleep".to_string()));

        let _ = filho.kill();
        let _ = filho.wait();
        let _ = fs::remove_file(caminho);
        assert!(other_openers(&caminho_str, 1).is_empty());
    }

    #[test]
    fn dispositivo_que_nao_existe_nao_gera_aviso() {
        assert_eq!(size_conflict_notice("/dev/nao-existe-cdc", (1, 1), 1), None);
    }
}
