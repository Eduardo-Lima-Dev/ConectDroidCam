//! Orientação e tamanho do vídeo entregue à webcam virtual.
//!
//! O codificador de um celular entrega os quadros na orientação do sensor, que é
//! sempre horizontal. Com o aparelho em pé a imagem chega deitada, e o emissor informa
//! em `profile.actual` quantos graus, no sentido horário, ela precisa girar. A webcam
//! virtual, porém, tem um formato fixo por sessão: se o celular girar, a saída não pode
//! mudar de tamanho, ou o OBS e os navegadores perdem o dispositivo. Por isso a imagem
//! já girada é encaixada num quadro de tamanho fixo, com barras pretas nas sobras.

/// Formato do quadro de saída.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Canvas {
    /// Decide pela posição do celular na hora de conectar: vertical se ele estiver em pé,
    /// horizontal se estiver deitado. Depois disso o formato não muda até a próxima conexão.
    #[default]
    Auto,
    /// Largura maior que a altura (por exemplo 1920×1080). É o formato de qualquer webcam.
    Horizontal,
    /// Altura maior que a largura (por exemplo 1080×1920), para quem usa o celular em pé.
    Vertical,
}

impl Canvas {
    /// Troca `Auto` pelo formato que combina com a `rotation` (graus) do celular.
    pub fn resolve(self, rotation: u32) -> Canvas {
        match self {
            Canvas::Auto if normalize_rotation(rotation) % 180 == 90 => Canvas::Vertical,
            Canvas::Auto => Canvas::Horizontal,
            outro => outro,
        }
    }
}

/// Tamanho do quadro entregue à webcam virtual, **independente da resolução do celular**.
///
/// A webcam virtual mantém o tamanho com que o OBS a abriu: se ele acompanhasse a resolução
/// do celular, trocar de HD para Full HD mudaria o tamanho e o OBS mostraria a imagem
/// embaralhada. Com um tamanho fixo, a imagem do celular é ajustada a ele, qualquer que seja
/// a resolução.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OutputSize {
    /// 1280×720.
    Hd,
    /// 1920×1080.
    #[default]
    FullHd,
    /// 2560×1440.
    Qhd,
}

impl OutputSize {
    /// Lado maior e lado menor, em pixels.
    pub fn edges(self) -> (u32, u32) {
        match self {
            OutputSize::Hd => (1280, 720),
            OutputSize::FullHd => (1920, 1080),
            OutputSize::Qhd => (2560, 1440),
        }
    }
}

/// Largura e altura do quadro de saída para o tamanho e o formato escolhidos.
pub fn canvas_size(size: OutputSize, canvas: Canvas) -> (u32, u32) {
    let (maior, menor) = size.edges();
    match canvas {
        Canvas::Vertical => (menor, maior),
        // `Auto` deve ser resolvido antes (`Canvas::resolve`); na dúvida, horizontal.
        Canvas::Horizontal | Canvas::Auto => (maior, menor),
    }
}

/// Aceita só 0, 90, 180 e 270; qualquer outro valor vira 0, para um emissor com defeito
/// não derrubar a saída.
pub fn normalize_rotation(degrees: u32) -> u32 {
    match degrees {
        90 | 180 | 270 => degrees,
        _ => 0,
    }
}

/// Filtro de vídeo do `ffmpeg` que gira o quadro e o encaixa no quadro de saída, ou `None`
/// se o quadro já chega pronto.
pub fn video_filter(
    src_width: u32,
    src_height: u32,
    rotation: u32,
    canvas_width: u32,
    canvas_height: u32,
) -> Option<String> {
    let rotation = normalize_rotation(rotation);
    let mut etapas: Vec<String> = Vec::new();
    match rotation {
        90 => etapas.push("transpose=1".into()),
        180 => etapas.push("transpose=1,transpose=1".into()),
        270 => etapas.push("transpose=2".into()),
        _ => {}
    }
    let (girada_w, girada_h) = if rotation.is_multiple_of(180) {
        (src_width, src_height)
    } else {
        (src_height, src_width)
    };
    if (girada_w, girada_h) != (canvas_width, canvas_height) {
        // `force_divisible_by=2` evita largura ímpar, que o formato de saída não aceita.
        etapas.push(format!(
            "scale={canvas_width}:{canvas_height}:force_original_aspect_ratio=decrease:force_divisible_by=2"
        ));
        etapas.push(format!(
            "pad={canvas_width}:{canvas_height}:(ow-iw)/2:(oh-ih)/2:black"
        ));
        etapas.push("setsar=1".into());
    }
    (!etapas.is_empty()).then(|| etapas.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn o_tamanho_da_saida_nao_depende_da_resolucao_do_celular() {
        // A mesma saída para qualquer resolução de entrada: é isso que mantém o OBS feliz.
        assert_eq!(
            canvas_size(OutputSize::FullHd, Canvas::Horizontal),
            (1920, 1080)
        );
        assert_eq!(
            canvas_size(OutputSize::FullHd, Canvas::Vertical),
            (1080, 1920)
        );
    }

    #[test]
    fn cada_tamanho_tem_seus_lados() {
        assert_eq!(canvas_size(OutputSize::Hd, Canvas::Horizontal), (1280, 720));
        assert_eq!(
            canvas_size(OutputSize::Qhd, Canvas::Horizontal),
            (2560, 1440)
        );
        assert_eq!(canvas_size(OutputSize::Qhd, Canvas::Vertical), (1440, 2560));
        assert_eq!(OutputSize::default(), OutputSize::FullHd);
    }

    #[test]
    fn auto_escolhe_vertical_com_o_celular_em_pe_e_horizontal_deitado() {
        assert_eq!(Canvas::Auto.resolve(90), Canvas::Vertical);
        assert_eq!(Canvas::Auto.resolve(270), Canvas::Vertical);
        assert_eq!(Canvas::Auto.resolve(0), Canvas::Horizontal);
        assert_eq!(Canvas::Auto.resolve(180), Canvas::Horizontal);
        // Rotação inválida vale 0.
        assert_eq!(Canvas::Auto.resolve(45), Canvas::Horizontal);
    }

    #[test]
    fn formato_explicito_nao_muda_com_a_rotacao() {
        assert_eq!(Canvas::Horizontal.resolve(90), Canvas::Horizontal);
        assert_eq!(Canvas::Vertical.resolve(0), Canvas::Vertical);
    }

    #[test]
    fn sem_rotacao_e_com_o_mesmo_tamanho_nao_precisa_de_filtro() {
        assert_eq!(video_filter(1920, 1080, 0, 1920, 1080), None);
        assert_eq!(
            video_filter(1920, 1080, 180, 1920, 1080).unwrap(),
            "transpose=1,transpose=1"
        );
    }

    #[test]
    fn video_de_outra_resolucao_e_ajustado_ao_tamanho_fixo_da_saida() {
        // HD num quadro Full HD: só escala, sem girar.
        let f = video_filter(1280, 720, 0, 1920, 1080).unwrap();
        assert!(f.starts_with("scale=1920:1080:force_original_aspect_ratio=decrease"));
        assert!(!f.contains("transpose"));
        // 4K em pé num quadro vertical Full HD: gira e reduz.
        let f = video_filter(3840, 2160, 90, 1080, 1920).unwrap();
        assert!(f.starts_with("transpose=1,scale=1080:1920"));
    }

    #[test]
    fn rotacao_de_90_graus_usa_transpose_horario() {
        assert_eq!(video_filter(640, 360, 90, 360, 640).unwrap(), "transpose=1");
        assert_eq!(
            video_filter(640, 360, 270, 360, 640).unwrap(),
            "transpose=2"
        );
    }

    #[test]
    fn imagem_em_pe_num_quadro_horizontal_ganha_barras() {
        let f = video_filter(1920, 1080, 90, 1920, 1080).unwrap();
        assert!(f.starts_with("transpose=1,scale=1920:1080:force_original_aspect_ratio=decrease"));
        assert!(f.contains("pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black"));
        assert!(f.ends_with("setsar=1"));
    }

    #[test]
    fn imagem_deitada_num_quadro_vertical_tambem_ganha_barras() {
        let f = video_filter(1920, 1080, 0, 1080, 1920).unwrap();
        assert!(f.starts_with("scale=1080:1920"));
    }

    #[test]
    fn rotacao_invalida_vira_zero() {
        assert_eq!(normalize_rotation(45), 0);
        assert_eq!(normalize_rotation(360), 0);
        assert_eq!(normalize_rotation(u32::MAX), 0);
        assert_eq!(video_filter(1920, 1080, 45, 1920, 1080), None);
    }
}
