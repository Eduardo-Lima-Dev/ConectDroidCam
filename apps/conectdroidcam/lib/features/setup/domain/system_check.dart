enum CheckStatus { ok, warning, problem, info }

class SystemCheck {
  const SystemCheck({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
    this.command,
  });

  final String id;
  final String title;
  final CheckStatus status;
  final String detail;
  final String? command;
}

class SystemFacts {
  const SystemFacts({
    required this.ffmpegOk,
    required this.ffmpegHint,
    required this.moduleLoaded,
    required this.secureBoot,
    required this.hasDeviceFamily,
    required this.hasLegacyDevice,
    required this.trayAvailable,
    required this.setupCommand,
  });

  final bool ffmpegOk;
  final String ffmpegHint;
  final bool moduleLoaded;
  final bool? secureBoot;
  final bool hasDeviceFamily;
  final bool hasLegacyDevice;
  final bool? trayAvailable;
  final String setupCommand;
}

List<SystemCheck> evaluateSystem(SystemFacts f) => [
  SystemCheck(
    id: 'ffmpeg',
    title: 'Decodificador de vídeo (ffmpeg)',
    status: f.ffmpegOk ? CheckStatus.ok : CheckStatus.problem,
    detail: f.ffmpegOk
        ? 'Encontrado. Ele transforma o vídeo do celular em imagem para a webcam virtual.'
        : f.ffmpegHint,
  ),
  SystemCheck(
    id: 'modulo',
    title: 'Módulo de webcam virtual (v4l2loopback)',
    status: f.moduleLoaded ? CheckStatus.ok : CheckStatus.problem,
    detail: f.moduleLoaded
        ? 'Carregado no sistema.'
        : 'O módulo não está carregado. Instale o pacote v4l2loopback da sua '
              'distribuição (Arch e Debian/Ubuntu: v4l2loopback-dkms; Fedora: '
              'akmod-v4l2loopback, do RPM Fusion) e rode o comando abaixo.',
    command: f.moduleLoaded ? null : f.setupCommand,
  ),
  if (f.secureBoot case final on?)
    SystemCheck(
      id: 'secureboot',
      title: 'Secure Boot',
      status: !on || f.moduleLoaded ? CheckStatus.ok : CheckStatus.warning,
      detail: !on
          ? 'Desligado: o módulo carrega sem precisar de assinatura.'
          : f.moduleLoaded
          ? 'Ligado, e o módulo carregou normalmente.'
          : 'Ligado. Com ele, o Linux só carrega módulos assinados. No Ubuntu, a '
                'instalação do v4l2loopback-dkms pede para cadastrar uma chave (MOK) '
                'na próxima reinicialização; aceite na tela azul que aparece. Em '
                'outras distribuições, veja como assinar módulos DKMS.',
    ),
  SystemCheck(
    id: 'webcams',
    title: 'Webcams do ConectDroidCam',
    status: f.hasDeviceFamily
        ? CheckStatus.ok
        : f.hasLegacyDevice
        ? CheckStatus.warning
        : CheckStatus.problem,
    detail: f.hasDeviceFamily
        ? 'Prontas: uma por tamanho e formato, para o OBS não perder a imagem ao trocar.'
        : f.hasLegacyDevice
        ? 'Há só a webcam única de uma versão anterior. Crie uma por tamanho e '
              'formato (feche o OBS antes) com o comando abaixo.'
        : 'Ainda não existem. Crie com o comando abaixo (pede a senha de administrador).',
    command: f.hasDeviceFamily ? null : f.setupCommand,
  ),
  if (f.trayAvailable case final tray?)
    SystemCheck(
      id: 'bandeja',
      title: 'Ícone na bandeja',
      status: tray ? CheckStatus.ok : CheckStatus.warning,
      detail: tray
          ? 'Disponível: fechar a janela mantém o app rodando no ícone da bandeja.'
          : 'Este ambiente gráfico não mostra ícones de bandeja. No GNOME, instale a '
                'extensão "AppIndicator and KStatusNotifierItem Support". Sem ela, '
                'fechar a janela com o celular conectado pergunta se o app deve '
                'continuar rodando escondido.',
    ),
  const SystemCheck(
    id: 'obs',
    title: 'OBS Studio',
    status: CheckStatus.info,
    detail:
        'No OBS, adicione a fonte "Dispositivo de captura de vídeo (V4L2)" e '
        'escolha a webcam ConectDroidCam do tamanho e formato que você usa. O OBS '
        'em Flatpak já enxerga as webcams, sem configuração extra.',
  ),
  const SystemCheck(
    id: 'rede',
    title: 'Rede',
    status: CheckStatus.info,
    detail:
        'O celular e o computador precisam estar no mesmo Wi-Fi. Se o celular não '
        'aparecer sozinho, o firewall pode estar bloqueando a descoberta (mDNS, '
        'porta UDP 5353): libere-a ou digite o endereço mostrado no celular. '
        'Com ufw: sudo ufw allow 5353/udp. Com firewalld: '
        'sudo firewall-cmd --permanent --add-service=mdns && sudo firewall-cmd --reload.',
  ),
];

bool hasBlockingProblem(List<SystemCheck> checks) =>
    checks.any((c) => c.status == CheckStatus.problem);
