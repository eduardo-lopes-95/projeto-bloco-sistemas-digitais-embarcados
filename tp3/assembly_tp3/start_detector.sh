#!/bin/bash

echo "========================================"
echo "🐾 Iniciando Dog Bowl Detector 🐾"
echo "========================================"

# 1. Limpa qualquer processo que tenha ficado travado de execuções anteriores
echo "[1/4] Limpando processos antigos..."
sudo pkill -f gpio_poll
pkill -f whatsapp_api.py

# 2. Inicia o código Assembly em segundo plano (usando o & no final)
echo "[2/4] Iniciando leitura de Hardware (Assembly)..."
sudo ./gpio_poll &

# Pequena pausa para garantir que o Assembly crie o arquivo no /dev/shm
sleep 1

# 3. Navega para a pasta da API e ativa o ambiente virtual
echo "[3/4] Carregando ambiente virtual Python..."
cd api/
source env/bin/activate

# 4. Inicia o monitoramento do WhatsApp no terminal principal
echo "[4/4] Iniciando API do WhatsApp..."
echo "----------------------------------------"
python whatsapp_api.py