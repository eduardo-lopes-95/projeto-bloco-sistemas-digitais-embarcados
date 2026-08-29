import time
import os
from twilio.rest import Client
from dotenv import load_dotenv

# Carrega as variáveis contidas no arquivo .env para o ambiente do sistema
load_dotenv()

# Recupera as credenciais de forma segura
account_sid = os.getenv('TWILIO_ACCOUNT_SID')
auth_token = os.getenv('TWILIO_AUTH_TOKEN')

# Recupera os números de WhatsApp do ambiente (nunca hardcoded)
whatsapp_from = os.getenv('WHATSAPP_NUMBER_FROM')  # número/sandbox da Twilio
whatsapp_to = os.getenv('WHATSAPP_NUMBER_TO')      # número que receberá o alerta

# Valida que todas as variáveis obrigatórias foram definidas no .env
required = {
    'TWILIO_ACCOUNT_SID': account_sid,
    'TWILIO_AUTH_TOKEN': auth_token,
    'WHATSAPP_NUMBER_FROM': whatsapp_from,
    'WHATSAPP_NUMBER_TO': whatsapp_to,
}
faltando = [nome for nome, valor in required.items() if not valor]
if faltando:
    raise SystemExit(
        "Erro: variáveis ausentes no .env: " + ", ".join(faltando) +
        "\nCrie um arquivo .env com essas chaves (veja o README)."
    )

# Inicializa o cliente da Twilio
client = Client(account_sid, auth_token)

STATUS_FILE = "/dev/shm/status_pote"

def enviar_whatsapp():
    try:
        message = client.messages.create(
            from_=f'whatsapp:{whatsapp_from}',
            body='⚠️ *Dog Bowl Detector* ⚠️\nO pote de ração está vazio! Por favor, abasteça.',
            to=f'whatsapp:{whatsapp_to}'
        )
        print(f"Notificação enviada com sucesso! SID: {message.sid}")
    except Exception as e:
        print(f"Erro ao enviar mensagem: {e}")

print("API de monitoramento do WhatsApp iniciada...")

# Estado anterior para evitar o envio de SPAM (enviar apenas na mudança de estado)
ultimo_estado = "0"

while True:
    # Verifica se o arquivo de status existe
    if os.path.exists(STATUS_FILE):
        with open(STATUS_FILE, "r") as f:
            estado_atual = f.read().strip()
        
        # Se o estado mudou de cheio (0) para vazio (1)
        if estado_atual == "1" and ultimo_estado == "0":
            print("Detectado: Pote Vazio! Disparando notificação...")
            enviar_whatsapp()
            ultimo_estado = "1"
        
        # Se o pote foi abastecido (sinal voltou para 0)
        elif estado_atual == "0" and ultimo_estado == "1":
            print("Detectado: Pote abastecido.")
            ultimo_estado = "0"
            
    time.sleep(1) # Amostragem a cada 1 segundo para não consumir CPU