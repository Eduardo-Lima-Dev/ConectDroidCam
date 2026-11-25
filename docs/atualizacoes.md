# Atualizações sem loja

O ConectDroidCam se atualiza a partir das releases do próprio repositório, sem Flathub nem Play Store. Cada push na `main` gera a release `build-N` (veja [flatpak.md](flatpak.md)), e é dela que as duas plataformas tiram a versão nova.

## Linux (Flatpak)

Quem atualiza é o Flatpak: pelo `flatpak update`, que atualiza todos os Flatpaks de uma vez, ou pela loja do sistema (GNOME Software, Discover).

Ao abrir, o app instalado pelo Flatpak de uma release consulta as releases do GitHub. Se houver um `build-N` mais novo que o seu, mostra o aviso **Nova versão disponível** com o comando `flatpak update io.github.eduardo_lima_dev.ConectDroidCam` e um botão para copiá-lo. O número do build é embutido na compilação pelo CI (`--dart-define=CDC_BUILD=N`); builds locais ficam com 0 e não mostram o aviso.

O repositório Flatpak publicado no GitHub Pages é assinado com uma chave GPG. O Flatpak recusa um repositório cuja assinatura não confere com a chave pública que o usuário cadastrou (está dentro do `.flatpakrepo`, do `.flatpakref` e do `.flatpak` das releases). A chave pública também está em [`flatpak/conectdroidcam-repo.gpg`](../flatpak/conectdroidcam-repo.gpg).

## Android

Ao abrir, o app consulta as releases do GitHub e compara o maior `build-N` que tem APK com o `versionCode` instalado. Se houver um mais novo, aparece o aviso **Nova versão disponível** com o botão **Atualizar**:

1. O app baixa o APK, conferindo o tamanho.
2. Na primeira vez, o Android pede para permitir que o ConectDroidCam instale apps (**Permitir**). Depois de permitir, volte e toque em **Instalar**.
3. O Android mostra a tela de confirmação da instalação.

Sem internet, ou com o GitHub fora, o app simplesmente não mostra o aviso.

Com o app fechado, o Android também procura versão nova a cada 6 horas (com internet), pelo WorkManager, e mostra a notificação **Nova versão do ConectDroidCam**. Tocar nela abre o app, onde está o botão **Atualizar**. Cada versão é avisada uma vez. No Android 13 ou mais novo, o app pede a permissão de notificação depois da permissão da câmera; sem ela, só o aviso dentro do app continua.

O WorkManager guarda as tarefas num banco Room e cria a classe `WorkDatabase_Impl` por reflexão, chamando o construtor sem argumentos. No build de release, o R8 remove esse construtor porque nada o chama diretamente, e o app fecha ao abrir (`NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init>`). Por isso o `android/app/proguard-rules.pro` mantém o construtor de toda subclasse de `RoomDatabase`, e o build de release usa esse arquivo. Para conferir num APK: `dexdump classes*.dex` precisa mostrar `<init>` em `WorkDatabase_Impl`.

O Android só atualiza um app se a versão nova tiver **a mesma assinatura** da instalada. Por isso:

- Todas as releases são assinadas com a mesma chave de release.
- Um app instalado a partir de um build de desenvolvimento (chave de debug) não aceita a atualização: o aviso explica que é preciso desinstalar uma vez e instalar o APK da release. Depois disso, as atualizações funcionam pelo próprio app. Desinstalar apaga os computadores pareados no celular.

## As chaves (importante)

| Chave | Para que serve | Segredos no GitHub |
|---|---|---|
| Keystore de release do Android (`android-release.jks`) | Assina o APK. Sem ela, nenhuma versão nova instala por cima da antiga. | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` |
| Chave GPG do repositório Flatpak | Assina o repositório. Sem ela, quem já instalou deixa de receber atualizações. | `FLATPAK_GPG_PRIVATE_KEY`, `FLATPAK_GPG_KEY_ID` |

As duas foram geradas em `~/.local/share/conectdroidcam-chaves/` (só o dono lê), com as senhas em `android-senhas.txt`. **Guarde uma cópia dessa pasta fora da máquina**, num cofre de senhas ou num disco seguro. Se uma delas se perder, não há como recuperá-la: os segredos do GitHub não podem ser lidos de volta, e trocar de chave obriga todos os usuários a reinstalar o app.

Para builds de release locais com a mesma chave, o Gradle lê `apps/conectdroidcam/android/key.properties` (fora do git):

```
storeFile=/home/<usuário>/.local/share/conectdroidcam-chaves/android-release.jks
storePassword=...
keyPassword=...
keyAlias=conectdroidcam
```

Sem esse arquivo e sem os segredos, o APK de release sai com a chave de debug, o que basta para desenvolvimento.
