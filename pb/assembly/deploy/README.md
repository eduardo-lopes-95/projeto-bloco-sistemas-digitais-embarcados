# Inicialização automática no Raspberry

## Forma recomendada: script Bash

Envie `start_bowl.sh`, Makefile, os fontes Assembly/Python, `deploy/` e `tests/`
para `/home/pi/pb`. No Raspberry, execute uma vez:

```bash
cd /home/pi/pb
bash start_bowl.sh --prepare
nano camera.env
nano whatsapp.env
bash start_bowl.sh
```

O primeiro comando instala os pacotes ausentes, cria o venv, instala os pacotes
Python e compila o Assembly. Cria configurações a partir dos exemplos somente
se ainda não existirem. A etapa sem argumentos valida as configurações, verifica
o dispositivo SPI, instala e habilita os dois serviços, e solicita sua partida.
**Esse comando habilita envio real de WhatsApp.** Solicita sudo quando necessário.
O terminal pode ser fechado depois. Não executa uma API HTTP local: inicia o
cliente que chama a API Twilio e o processo de captura/classificação.

A cada boot o serviço executa `bash /home/pi/pb/start_bowl.sh --check-camera`
como usuário pi. O teste busca a imagem e usa a mesma conversão ffmpeg da captura.
Se a câmera não estiver disponível, systemd tenta iniciar novamente após 5 s.
Uma vez iniciada, a captura já repete os ciclos diante de falhas.
As dependências **não são reinstaladas no boot**; o sistema usa o ambiente
preparado. Execute o script normal novamente quando atualizar os arquivos.
Um manifesto inalterado e imports funcionais evitam reinstalação via pip.

O script não inicia o aplicativo IP Webcam remotamente, não programa a Tang
e não configura SPI sozinho. Habilite SPI pelo raspi-config previamente e grave
o bitstream na memória não volátil. Não instale outra cópia de captura/autostart
em paralelo. Credenciais existentes e estado persistente do episódio são preservados.

Diagnóstico:

```bash
bash /home/pi/pb/start_bowl.sh --check-camera
systemctl status bowl-capture bowl-notifier --no-pager
journalctl -u bowl-capture -u bowl-notifier -f
cat /run/bowl/result.json
cat /var/lib/bowl-notifier/state.json
```

`active` no notificador não comprova envio ou entrega: confira estado, SID e o
WhatsApp destinatário. Durante a espera pela câmera, capture pode mostrar
`activating` ou `auto-restart`. A saída do instalador confirma solicitação de
partida, não sucesso do hardware. Para desabilitar: `sudo systemctl disable --now
bowl-notifier bowl-capture`.

Os passos manuais abaixo explicam os componentes e servem para diagnóstico;
não é necessário repetir a instalação manual após usar o script.

Destino: `/home/pi/pb`, usuário `pi`, Raspberry Pi OS 64 bits e systemd.
O celular serve snapshots HTTP; o Raspberry busca as imagens. A Tang deve
carregar o bitstream SPI da memória não volátil ao ligar. Não é necessário
terminal aberto após a instalação, mas IP Webcam deve estar servindo imagens.
Reserve o IP 192.168.1.110 no roteador e configure a inicialização do servidor
no celular conforme a versão do aplicativo. Teste com tela bloqueada e após reboot.

## Transferência pelo PowerShell do Windows, na raiz do repositório

```powershell
ssh pi@192.168.1.210 "mkdir -p /home/pi/pb"
scp pb/assembly/start_bowl.sh pb/assembly/Makefile pb/assembly/spi_image_client.s pb/assembly/camera_capture.py pb/assembly/bowl_notifier.py pi@192.168.1.210:/home/pi/pb/
scp -r pb/assembly/deploy pb/assembly/tests pi@192.168.1.210:/home/pi/pb/
```

Não copie arquivos de recuperação 2FA nem credenciais do repositório.

## Preparação única no Raspberry

```bash
cd /home/pi/pb
uname -m                         # precisa mostrar aarch64
sudo apt update
sudo apt install -y build-essential python3-venv ffmpeg curl
sudo raspi-config               # Interface Options -> SPI -> Enable
sudo usermod -aG spi pi
```

Faça logout/login para aplicar o grupo; reinicie se necessário para SPI.
Depois:

```bash
cd /home/pi/pb
ls -l /dev/spidev0.0
make
make test
make test-assembly
python3 -m venv .venv
.venv/bin/pip install -r deploy/requirements.txt
# Cria apenas se ainda não existem; não sobrescreve configurações existentes.
(umask 077; test -e camera.env || cp deploy/camera.env.example camera.env)
(umask 077; test -e whatsapp.env || cp deploy/whatsapp.env.example whatsapp.env)
chmod 600 camera.env whatsapp.env
nano camera.env
nano whatsapp.env
```

Edite os valores REPLACE_WITH... somente no Pi. Números em formato
`whatsapp:+55...`. O remetente é o número habilitado pela Twilio, não
necessariamente o número do celular com a câmera.

Para Sandbox, o destinatário precisa aderir usando o `join` indicado no console.
Texto livre depende da janela de atendimento de 24 horas. Para operação
autônoma fora dessa janela, configure remetente de produção e template aprovado
via TWILIO_CONTENT_SID. O cliente atual não passa ContentVariables: use template
sem variáveis. Sandbox é para testes, não uma garantia de operação permanente.

Fontes: https://www.twilio.com/docs/whatsapp/sandbox e
https://www.twilio.com/docs/whatsapp/tutorial/send-whatsapp-notification-messages-templates

## Verificação antes do serviço

O endereço base informado é a interface web. `/shot.jpg` é a URL candidata de
snapshot; confirme no Raspberry:

```bash
curl --fail --max-time 10 http://192.168.1.110:8080/shot.jpg -o /tmp/bowl-camera.jpg
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height /tmp/bowl-camera.jpg
```

Se não retornar imagem válida, use a URL de fotografia exibida pelo IP Webcam
em camera.env. O serviço não deve consumir a página HTML nem o fluxo de vídeo.

## Instalação e ativação

```bash
sudo install -m 644 deploy/bowl-capture.service deploy/bowl-notifier.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now bowl-capture.service
cat /run/bowl/result.json
journalctl -u bowl-capture.service -n 20 --no-pager
```

Aguarde um ciclo. Exija valid=true, error=NONE, total=19200 e classificações
corretas com pote cheio/vazio; calibre THRESHOLD e CROP_ARGS se necessário.
Use `sudo systemctl restart bowl-capture` após editar camera.env.
Falhas publicam invalid/unknown e o processo tenta no ciclo seguinte.

Com câmera, SPI e credenciais prontos, o comando seguinte **habilita envio real**:

```bash
sudo systemctl enable --now bowl-notifier.service
systemctl is-enabled bowl-capture bowl-notifier
systemctl is-active bowl-capture bowl-notifier
journalctl -u bowl-capture -u bowl-notifier -f
```

Ctrl+C encerra somente a visualização dos logs. Três frames vazios distintos e
recentes disparam uma tentativa. Dois cheios rearmam. Um pote persistentemente
vazio não repete o alerta, inclusive após reboot, pois o episódio fica salvo
em `/var/lib/bowl-notifier/state.json`.

```bash
cat /var/lib/bowl-notifier/state.json
sudo reboot
```

Após reboot, conferir serviços, imagem recente e estado. Repetir cheio -> vazio
para um novo episódio, conferir recebimento no WhatsApp e status no console Twilio.
`accepted` com SID significa aceitação da API, não entrega confirmada.
`pending`/`unknown` não são reenviados automaticamente para evitar duplicidade;
investigue antes de qualquer tentativa manual. Não apague o estado como rotina.
Esta política não garante entrega durante indisponibilidade da Internet/provedor.

Para interromper:

```bash
sudo systemctl disable --now bowl-notifier bowl-capture
```

Os serviços usam `/run/bowl/result.json` para evitar resultados de um boot
anterior. Credenciais são carregadas só pelo notifier. O estado do episódio é
persistente. Não rode outro produtor manual contra o mesmo dispositivo SPI.
