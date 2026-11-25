#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Canvas {
    #[default]
    Auto,
    Horizontal,
    Vertical,
}

impl Canvas {
    pub fn resolve(self, rotation: u32) -> Canvas {
        match self {
            Canvas::Auto if normalize_rotation(rotation) % 180 == 90 => Canvas::Vertical,
            Canvas::Auto => Canvas::Horizontal,
            outro => outro,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OutputSize {
    Hd,
    #[default]
    FullHd,
    Qhd,
}

impl OutputSize {
    pub fn edges(self) -> (u32, u32) {
        match self {
            OutputSize::Hd => (1280, 720),
            OutputSize::FullHd => (1920, 1080),
            OutputSize::Qhd => (2560, 1440),
        }
    }
}

pub fn canvas_size(size: OutputSize, canvas: Canvas) -> (u32, u32) {
    let (maior, menor) = size.edges();
    match canvas {
        Canvas::Vertical => (menor, maior),
        Canvas::Horizontal | Canvas::Auto => (maior, menor),
    }
}

pub fn normalize_rotation(degrees: u32) -> u32 {
    match degrees {
        90 | 180 | 270 => degrees,
        _ => 0,
    }
}

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
        let f = video_filter(1280, 720, 0, 1920, 1080).unwrap();
        assert!(f.starts_with("scale=1920:1080:force_original_aspect_ratio=decrease"));
        assert!(!f.contains("transpose"));
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
