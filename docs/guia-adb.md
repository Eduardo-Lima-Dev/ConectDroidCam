# Conectar o celular Android pelo ADB

Para rodar e depurar o app direto no celular, sem emulador, o computador precisa enxergá-lo pelo **ADB** (Android Debug Bridge). Este guia vale para **Linux** e **macOS**. Há dois jeitos: por cabo USB ou por Wi-Fi.

> O ADB é só para desenvolver. Usar o ConectDroidCam como webcam não exige ADB.

## 1. Instalar o ADB no computador

| Sistema | Comando |
|---|---|
| Arch Linux | `sudo pacman -S android-tools` |
| Debian e Ubuntu | `sudo apt install adb` |
| Fedora | `sudo dnf install android-tools` |
| macOS (Homebrew) | `brew install --cask android-platform-tools` |
| Qualquer um | Baixar as "SDK Platform-Tools" no site do Android Developers e colocar a pasta no `PATH` |

Se você já instalou o Android Studio, o ADB vem junto, em `~/Android/Sdk/platform-tools` (Linux) ou `~/Library/Android/sdk/platform-tools` (macOS). Confira com:

```sh
adb version
```

## 2. Preparar o celular

1. Abra **Configurações › Sobre o telefone** e toque 7 vezes em **Número da versão** (em alguns Xiaomi, **Versão do MIUI**). Isso libera as **Opções do desenvolvedor**.
2. Entre em **Opções do desenvolvedor** (em geral em Configurações › Sistema).
3. Ative a **Depuração USB** se for usar cabo, ou a **Depuração por Wi-Fi** se for usar a rede.

## 3. Opção A: cabo USB

1. Ligue o celular ao computador com um cabo que transmita dados (alguns só carregam).
2. No celular, escolha o modo **Transferência de arquivos** se ele perguntar.
3. Aceite a janela **Permitir depuração USB?** (marque "Sempre permitir neste computador").
4. No computador:

```sh
adb devices
```

O celular deve aparecer com o estado `device`.

## 4. Opção B: Wi-Fi (Android 11 ou mais novo)

O computador e o celular precisam estar na **mesma rede** (ou mesma faixa de IP, como `192.168.0.x`). O Wi-Fi do celular pode ser diferente da conexão do computador, por exemplo cabo no PC e Wi-Fi no celular, desde que o roteador deixe as duas se enxergarem.

### 4.1 Parear (só na primeira vez)

1. Em **Opções do desenvolvedor › Depuração por Wi-Fi**, ative a chave e toque em **Parear dispositivo com código de pareamento**.
2. Aparece uma janela com um **IP:porta** e um **código de 6 dígitos**. Deixe-a aberta, porque o código expira rápido.
3. No computador, use o IP:porta **dessa janela**:

```sh
adb pair 192.168.0.7:37215
```

O terminal pede `Enter pairing code:`. Digite os 6 dígitos. A resposta esperada é `Successfully paired to ...`.

### 4.2 Conectar

A tela principal de **Depuração por Wi-Fi** mostra outro **IP:porta**, diferente do pareamento. Use esse:

```sh
adb connect 192.168.0.7:42857
adb devices
```

Depois de pareado uma vez, o computador costuma reconhecer o celular sozinho enquanto a Depuração por Wi-Fi estiver ligada. Para ver o que está sendo anunciado na rede:

```sh
adb mdns services
```

### 4.3 A porta muda

A porta de conexão **muda** quando você desliga e liga a Depuração por Wi-Fi, reinicia o celular ou troca de rede. Se o `adb connect` disser `Connection refused` ou `failed to connect`, abra a tela de Depuração por Wi-Fi, leia o `IP:porta` atual e conecte de novo. O pareamento não precisa ser refeito.

O `adb mdns services` pode continuar mostrando a porta antiga por um tempo. Confie no número que está na tela do celular.

### 4.4 A depuração por Wi-Fi fecha sozinha

Isso é do próprio Android: a Depuração por Wi-Fi **desliga** quando o celular sai da rede ou troca de Wi-Fi, ao reiniciar, e a porta sorteada deixa de valer. Sem acesso root, o Android não oferece uma opção para mantê-la sempre ativa. O que ajuda, do mais ao menos estável:

1. **Cabo USB.** É o único modo que não cai sozinho. Se for desenvolver por horas, use-o.
2. **Porta fixa com `adb tcpip`.** Com o celular já conectado (por USB ou pela própria Depuração por Wi-Fi), rode:

   ```sh
   adb tcpip 5555
   adb connect 192.168.0.7:5555
   ```

   A porta passa a ser sempre a **5555**, não precisa de código de pareamento e vale até o celular **reiniciar**. O ADB continua exigindo que o computador seja autorizado pela janela "Permitir depuração USB?". Dois cuidados: o IP do celular pode mudar (reserve um IP fixo para ele no roteador) e, depois de reiniciar, é preciso repetir o `adb tcpip 5555` com o celular ligado ao cabo. Para voltar ao modo normal: `adb usb`.
3. **Deixar a tela ligada durante o teste.** Em Opções do desenvolvedor, ative **Manter ativo** (a tela não apaga enquanto carrega). Tela apagada e economia de energia agressiva são causas comuns de queda.
4. **Chave que não expira.** Em versões recentes do Android há, em Opções do desenvolvedor, uma opção para **desativar o tempo limite de autorização do ADB**; sem ela, a autorização pode ser revogada depois de alguns dias e o pareamento precisa ser refeito. O nome exato varia por fabricante.

## 5. Rodar o app no celular

Com o celular aparecendo no `adb devices`:

```sh
cd apps/conectdroidcam
flutter devices          # confirma que o Flutter também enxerga o celular
flutter run -d <id>      # roda com hot reload; <id> é o da coluna do meio
```

Sem `-d`, o Flutter pergunta qual aparelho usar se houver mais de um.

Na primeira execução o app pede a permissão de câmera. Aceite no celular.

## 6. Testar o emissor a partir do computador

Com o app aberto, escolha a resolução e toque em **Iniciar transmissão**. A tela mostra o endereço do celular, como `192.168.0.7:47821`. No computador:

```sh
cd rust
cargo run -p cdc-testreceiver -- 192.168.0.7:47821 --seconds 20
```

O receptor imprime a resolução real, os FPS, o bitrate e o maior intervalo entre frames. Para escrever o vídeo em um dispositivo de webcam virtual do Linux, acrescente `--v4l2 /dev/video10` (veja [protocol-v1.md](protocol-v1.md) e [decisoes/fase1-spikes.md](decisoes/fase1-spikes.md)).

### Por cabo, sem depender do Wi-Fi

Com o celular conectado por USB, o ADB pode encaminhar a porta do app para o computador:

```sh
adb forward tcp:47821 tcp:47821
cargo run -p cdc-testreceiver -- 127.0.0.1:47821 --seconds 20
```

> Este encaminhamento é o desenho previsto para o modo USB do projeto, mas **ainda não foi testado** com o app.

## 7. Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `adb devices` não lista nada | Teste outro cabo e outra porta USB. Confirme o modo "Transferência de arquivos". No Linux, confira se seu usuário tem acesso ao dispositivo (regras udev do pacote `android-udev` ou similar). |
| Estado `unauthorized` | Olhe a tela do celular e aceite a janela de autorização. Se ela não aparece, em Opções do desenvolvedor use **Revogar autorizações de depuração USB** e reconecte. |
| Estado `offline` | `adb kill-server` e depois `adb devices`. Se continuar, reinicie a Depuração USB ou por Wi-Fi. |
| `failed to connect` ou `Connection refused` no Wi-Fi | A porta mudou: leia a atual na tela do celular (seção 4.3). |
| `failed to authenticate` | O pareamento não foi feito ou foi perdido: refaça a seção 4.1. |
| O celular aparece duas vezes (um deles com `(2)`) | É o mesmo aparelho em duas conexões. Use `adb -t <id> ...` com o `transport_id` de `adb devices -l`, ou `adb disconnect` e conecte só uma. |
| Pareia, mas não conecta | A rede pode isolar os aparelhos (comum em "rede de convidados"). Use a rede principal ou o cabo USB. |
| A conexão por Wi-Fi cai sozinha | Veja a seção 4.4: o Android desliga a Depuração por Wi-Fi ao trocar de rede ou reiniciar. Use o cabo USB ou a porta fixa com `adb tcpip 5555`. |
| `adb pair` fica sem resposta | Confirme que a janela de pareamento ainda está aberta e use o IP:porta e o código **dessa janela**. |

### Específico do macOS

- Na primeira vez, o macOS pode perguntar se o `adb` pode **aceitar conexões de rede**. Permita.
- Em versões recentes do macOS, o app de terminal que você usa pode precisar de acesso à **rede local**: veja **Ajustes do Sistema › Privacidade e Segurança › Rede local** e ative-o para o seu terminal. Sem isso, o `adb` não acha o celular na rede.

### Específico do Linux

- Se você usa firewall (`ufw`, `firewalld`), o ADB por Wi-Fi só faz conexões de saída do computador para o celular, então em geral não é preciso abrir portas.
- Quem inicia a conexão do vídeo é o computador, não o celular: o computador se conecta ao celular, na porta 47821. Por isso não é preciso abrir portas de entrada no computador.

### Específico de celulares Xiaomi (MIUI/HyperOS)

- **Instalar via USB** e **Depuração USB (configurações de segurança)** são opções separadas em Opções do desenvolvedor. Algumas operações do `adb` (como `pm grant`, para conceder permissões de fora) só funcionam com a segunda ligada. O app não depende disso: ele pede as permissões na tela.
