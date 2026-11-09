# Preparar o Mac (iOS e macOS)

Passo a passo para deixar um Mac pronto para compilar o ConectDroidCam para **iPhone** e **macOS**. Destrava os spikes S5, S6 e S7 do [roadmap](roadmap.md).

> **Este guia não foi testado.** Foi escrito a partir da documentação das ferramentas, sem um Mac à mão. Se algum passo mudou, corrija aqui.

## 1. Ferramentas

1. **Xcode**, pela App Store. Abra-o uma vez, aceite a licença e deixe instalar os componentes extras. Em **Xcode › Settings › Components** (ou **Platforms**), instale o suporte a iOS.
2. **Ferramentas de linha de comando:** `xcode-select --install`.
3. **Homebrew:** siga a instalação do site oficial (brew.sh).
4. **Flutter na versão exata do projeto** (3.44.4, arquivo `.flutter-version`):

   ```sh
   git clone https://github.com/flutter/flutter.git --branch 3.44.4 ~/flutter
   export PATH="$HOME/flutter/bin:$PATH"     # coloque também no ~/.zshrc
   flutter --version                         # deve dizer 3.44.4
   flutter doctor
   ```
5. **CocoaPods:** `brew install cocoapods`.
6. **Rust** (necessário quando o núcleo em Rust entrar no app):

   ```sh
   curl https://sh.rustup.rs -sSf | sh
   rustup target add aarch64-apple-ios aarch64-apple-darwin
   ```
7. **Ferramentas de apoio:** `brew install ffmpeg libimobiledevice` (o `ffmpeg` roda os testes do Rust; a `libusbmuxd`, que vem com a `libimobiledevice`, traz o `iproxy`, usado no spike de USB do iPhone).

## 2. Baixar o projeto e conferir o ambiente

```sh
git clone git@github.com:Eduardo-Lima-Dev/ConectDroidCam.git
cd ConectDroidCam/apps/conectdroidcam
flutter pub get
flutter analyze && flutter test
```

Os mesmos passos do [guia de desenvolvimento](desenvolvimento.md) valem aqui.

## 3. Rodar no iPhone com um Apple ID gratuito

Sem conta paga de desenvolvedor, o app é instalado por um perfil de desenvolvimento que **expira em cerca de 7 dias** (depois é só instalar de novo) e não há TestFlight.

1. Em **Xcode › Settings › Accounts**, adicione o seu Apple ID.
2. Abra `apps/conectdroidcam/ios/Runner.xcworkspace` (o `.xcworkspace`, não o `.xcodeproj`).
3. Selecione o alvo **Runner › Signing & Capabilities** e escolha o seu **Personal Team**. Se o Xcode reclamar do identificador `dev.eduardolima.conectdroidcam`, troque por um único (por exemplo, com o seu sobrenome) só na sua máquina e não o versione.
4. Conecte o iPhone por cabo e toque em **Confiar** nele.
5. No iPhone (iOS 16 ou mais novo), ative **Ajustes › Privacidade e Segurança › Modo Desenvolvedor** e reinicie quando pedir.
6. No terminal: `flutter devices` (o iPhone deve aparecer) e `flutter run -d <id do iPhone>`.
7. Na primeira vez, o iPhone bloqueia o app: em **Ajustes › Geral › VPN e Gerenciamento de Dispositivo**, confie no seu Apple ID.

Para depurar sem cabo depois da primeira vez: **Xcode › Window › Devices and Simulators**, selecione o iPhone e marque **Connect via network**.

## 4. Rodar o app no macOS

```sh
flutter run -d macos
```

O projeto já tem o alvo macOS (o Flutter está com o suporte a macOS ligado).

## 5. O que cada spike precisa responder

Registre os resultados em [decisoes/fase1-spikes.md](decisoes/fase1-spikes.md), com o aparelho, a versão do sistema e o que **não** foi provado.

| Spike | Pergunta | Como começar |
|---|---|---|
| S5 | Um iPhone físico consegue **escutar** em TCP com uma identidade TLS própria (P-256) e entregar H.264 do VideoToolbox, e um computador consegue conectar? | Um servidor mínimo com Network.framework, `NWListener` com opções TLS, e o `cdc-testreceiver` do outro lado. Teste também o aviso de rede local (`NSLocalNetworkUsageDescription`) |
| S6 | O OBS no Mac carrega um **plugin próprio** sem assinatura paga e mostra vídeo e áudio recebidos? | Um plugin mínimo sobre o `libobs`, com fonte assíncrona; observe o que o Gatekeeper e a "Validação de bibliotecas" do OBS exigem |
| S7 | Uma **extensão de câmera** (CoreMediaIO) instala com um Apple ID gratuito? | Crie o alvo no Xcode e tente instalar. A entitlement de extensão de sistema é restrita e a documentação não afirma o que uma conta gratuita obtém; o resultado precisa ser registrado, qualquer que seja |
| S4 (iPhone) | O `iproxy` encaminha a porta do app para o Mac e o fluxo funciona igual ao Wi-Fi? | Com o app do S5 ouvindo no iPhone, `iproxy 47821 47821` e conecte o `cdc-testreceiver` em `127.0.0.1:47821` |

## 6. Rodar a CI no Mac

Em repositório privado, os minutos de macOS do GitHub Actions rendem pouco. O plano é um **runner próprio** neste Mac para os jobs de macOS e iOS (build do app, do plugin do OBS e do iOS sem assinatura). Ainda não foi configurado.
