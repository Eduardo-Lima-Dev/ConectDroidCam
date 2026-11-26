import 'package:conectdroidcam/features/receiver/domain/friendly_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('erros de rede comuns viram frases claras com detalhes', () {
    final casos = {
      'Connection refused (os error 111)': 'recusou a conexão',
      'connection timed out': 'não respondeu a tempo',
      'No route to host (os error 113)': 'alcançar o celular',
      'failed to lookup address information: Name or service not known':
          'Não encontrei esse endereço',
      'Connection reset by peer (os error 104)': 'conexão com o celular caiu',
      'o certificado do outro lado mudou (esperado a, recebido b)':
          'não é o registrado no pareamento',
      'falha no TLS: handshake': 'conexão segura',
    };
    casos.forEach((bruto, esperado) {
      final f = friendlyError(bruto);
      expect(f.message, contains(esperado), reason: bruto);
      expect(f.details, bruto, reason: bruto);
    });
  });

  test('erro desconhecido passa como está, com a primeira letra maiúscula', () {
    final f = friendlyError('o ffmpeg parou: Device or resource busy');
    expect(f.message, 'O ffmpeg parou: Device or resource busy');
    expect(f.details, isNull);
  });

  test('nome do sistema do celular', () {
    expect(platformLabel('android'), 'Android');
    expect(platformLabel('ios'), 'iOS');
    expect(platformLabel('outro'), 'outro');
  });
}
