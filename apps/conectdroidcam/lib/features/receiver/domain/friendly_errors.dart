class FriendlyError {
  const FriendlyError(this.message, [this.details]);

  final String message;
  final String? details;
}

FriendlyError friendlyError(String raw) {
  final text = raw.trim();
  final lower = text.toLowerCase();
  bool has(List<String> parts) => parts.any(lower.contains);

  final message = switch (lower) {
    _
        when has([
          'certificado do outro lado mudou',
          'impressão digital diferente',
        ]) =>
      'O certificado do celular não é o registrado no pareamento. Se o app foi '
          'reinstalado no celular, remova o pareamento e pareie de novo. Se não foi, '
          'alguém pode estar se passando pelo celular: não continue.',
    _ when has(['connection refused', 'os error 111']) =>
      'O celular recusou a conexão. Confira se o ConectDroidCam está aberto nele, '
          'na tela da câmera.',
    _ when has(['timed out', 'os error 110']) =>
      'O celular não respondeu a tempo. Confira se ele está no mesmo Wi-Fi deste '
          'computador e com o ConectDroidCam aberto.',
    _
        when has([
          'no route to host',
          'os error 113',
          'network is unreachable',
          'os error 101',
          'host is unreachable',
        ]) =>
      'Não consegui alcançar o celular pela rede. Confira o endereço e se os dois '
          'estão no mesmo Wi-Fi.',
    _
        when has([
          'failed to lookup address',
          'name or service not known',
          'name does not resolve',
          'temporary failure in name resolution',
        ]) =>
      'Não encontrei esse endereço na rede. Confira o que foi digitado.',
    _
        when has([
          'connection reset',
          'os error 104',
          'broken pipe',
          'os error 32',
        ]) =>
      'A conexão com o celular caiu.',
    _ when has(['falha no tls']) =>
      'A conexão segura com o celular falhou. Confira se os dois apps estão '
          'atualizados.',
    _ => null,
  };
  if (message != null) return FriendlyError(message, text);
  return FriendlyError(_capitalize(text));
}

String _capitalize(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

String platformLabel(String platform) => switch (platform.toLowerCase()) {
  'android' => 'Android',
  'ios' => 'iOS',
  _ => platform,
};
