use std::collections::VecDeque;

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Report {
    pub actual: Option<(u32, u32, u32)>,
    pub video_frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub seconds: f64,
    pub avg_fps: f64,
    pub avg_kbps: f64,
    pub max_gap_ms: f64,
    pub lag_p50_ms: f64,
    pub lag_p95_ms: f64,
    pub lag_max_ms: f64,
    pub received_config: bool,
}

pub fn percentile(ordenados: &[f64], p: f64) -> f64 {
    if ordenados.is_empty() {
        return 0.0;
    }
    let posto = ((p / 100.0) * ordenados.len() as f64).ceil() as usize;
    ordenados[posto.clamp(1, ordenados.len()) - 1]
}

const MAX_LAG_SAMPLES: usize = 20_000;

#[derive(Debug, Default)]
pub struct LagTracker {
    origin: Option<(std::time::Instant, u64)>,
    best: f64,
    samples: VecDeque<f64>,
    window_max: f64,
}

impl LagTracker {
    pub fn record(&mut self, now: std::time::Instant, pts_us: u64) {
        let (inicio, pts0) = *self.origin.get_or_insert((now, pts_us));
        let chegada_ms = now.duration_since(inicio).as_secs_f64() * 1000.0;
        let previsto_ms = pts_us.saturating_sub(pts0) as f64 / 1000.0;
        let bruto = chegada_ms - previsto_ms;
        if self.samples.is_empty() || bruto < self.best {
            self.best = bruto;
        }
        if self.samples.len() == MAX_LAG_SAMPLES {
            self.samples.pop_front();
        }
        self.samples.push_back(bruto);
        self.window_max = self.window_max.max(bruto - self.best);
    }

    pub fn take_window_max(&mut self) -> f64 {
        std::mem::take(&mut self.window_max)
    }

    pub fn fill(&self, report: &mut Report) {
        let Some(melhor) = self.samples.iter().copied().reduce(f64::min) else {
            return;
        };
        let mut ordenados: Vec<f64> = self.samples.iter().map(|l| l - melhor).collect();
        ordenados.sort_by(f64::total_cmp);
        report.lag_p50_ms = percentile(&ordenados, 50.0);
        report.lag_p95_ms = percentile(&ordenados, 95.0);
        report.lag_max_ms = ordenados.last().copied().unwrap_or(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn percentil_pelo_posto_mais_proximo() {
        let v: Vec<f64> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&v, 50.0), 50.0);
        assert_eq!(percentile(&v, 95.0), 95.0);
        assert_eq!(percentile(&v, 100.0), 100.0);
        assert_eq!(percentile(&v, 0.0), 1.0);
    }

    #[test]
    fn percentil_de_lista_vazia_e_zero() {
        assert_eq!(percentile(&[], 95.0), 0.0);
    }

    #[test]
    fn percentil_de_um_valor_e_ele_mesmo() {
        assert_eq!(percentile(&[7.5], 95.0), 7.5);
    }

    #[test]
    fn atraso_e_medido_contra_o_melhor_caso() {
        let t0 = Instant::now();
        let mut lag = LagTracker::default();
        lag.record(t0, 0);
        lag.record(t0 + Duration::from_millis(33), 33_000);
        lag.record(t0 + Duration::from_millis(146), 66_000);
        assert!((lag.take_window_max() - 80.0).abs() < 1.0);
        assert_eq!(lag.take_window_max(), 0.0);

        let mut r = Report::default();
        lag.fill(&mut r);
        assert!((r.lag_max_ms - 80.0).abs() < 1.0);
        assert!(r.lag_p50_ms < 1.0);
    }

    #[test]
    fn guarda_so_as_amostras_mais_recentes() {
        let t0 = Instant::now();
        let mut lag = LagTracker::default();
        for i in 0..(MAX_LAG_SAMPLES as u64 + 500) {
            lag.record(t0 + Duration::from_millis(i * 33), i * 33_000);
        }
        assert_eq!(lag.samples.len(), MAX_LAG_SAMPLES);
    }
}
