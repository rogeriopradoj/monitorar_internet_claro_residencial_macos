# Monitor de Internet Claro Residencial para macOS

Um monitor Bash, sem instalações adicionais, para investigar conexão instável da Claro residencial quando o Mac está conectado diretamente ao modem em modo bridge.

Ele registra medições recorrentes em CSV e eventos em log para separar falhas do primeiro salto, Internet, DNS, HTTPS e IPv6. Ao encerrar, produz um resumo textual com perda, latência e jitter.

## Contexto

Este projeto nasceu de uma investigação de intermitência em uma instalação Claro residencial. O modem opera em bridge e entrega IPs públicos dinâmicos a dois equipamentos: um gateway/roteador da rede principal e um homelab para uma rede IoT.

Como a degradação aparecia em ambas as portas/IPs, o diagnóstico precisava excluir Wi-Fi, mesh, roteamento e NAT. A solução foi conectar um Mac diretamente ao modem, onde ele recebeu um IP público e um gateway da Claro, e manter medições comparáveis por algumas horas.

Os testes pontuais iniciais mostraram boa capacidade de banda e nenhuma perda no momento da medição — aproximadamente 934 Mbps de download e 117 Mbps de upload no Speedtest, cerca de 990/110 Mbps no Fast — mas latência sob carga alta, chegando a aproximadamente 544 ms. Por isso, este projeto não tenta substituir um teste de velocidade isolado: ele constrói uma linha do tempo para correlacionar as falhas com o horário e a camada afetada.

## O que é medido

Em cada ciclo, o script coleta:

- Ping ao gateway IPv4 da Claro (primeiro salto).
- Ping a `1.1.1.1` e `8.8.8.8` para conectividade externa independente de DNS.
- Resolução DNS pelo resolvedor configurado no Mac e diretamente pelo `1.1.1.1`, em UDP e TCP.
- Requisição HTTPS à Cloudflare em IPv4 e IPv6, além de uma requisição IPv4 com o IP já resolvido para separar DNS de conexão TCP/HTTPS.
- `networkQuality` do macOS quando disponível, em frequência configurável.

Os testes de ping registram transmissão, recepção, perda, mínimo, média, máximo e desvio-padrão (usado como indicador de jitter). Eventos de perda, latência ou jitter acima dos limiares do script são destacados no log.

## Requisitos

- macOS com `bash`, `ping`, `awk`, `curl` e ferramentas de rede nativas.
- Conexão Ethernet direta ao modem para isolar o teste, se esse for o objetivo do diagnóstico.
- `networkQuality` é opcional: o script segue funcionando caso não esteja disponível.

Não requer `brew`, Docker, Python, Node.js ou serviços externos instalados.

O gateway é detectado automaticamente a partir da rota padrão do macOS. Caso o Mac tenha VPN, múltiplas rotas ou uma topologia incomum, informe-o explicitamente com `--gateway IPV4`.

## Instalação

```bash
git clone https://github.com/rogeriopradoj/monitorar_internet_claro_residencial_macos.git
cd monitorar_internet_claro_residencial_macos
chmod +x monitorar_claro_macos.sh
```

## Uso

O comando abaixo usa os valores adequados ao cenário original: duas horas de monitoração, um ciclo a cada cinco minutos, dez pings por destino e `networkQuality` aproximadamente a cada 20 minutos.

```bash
./monitorar_claro_macos.sh
```

Para conferir todas as opções:

```bash
./monitorar_claro_macos.sh --help
```

Exemplo de uma sessão de uma hora, a cada dois minutos, gravando os resultados em uma pasta explícita:

```bash
./monitorar_claro_macos.sh \
  --duration 60 \
  --interval 2 \
  --output-dir resultados/2026-08-22-noite
```

Para executar `networkQuality` em todos os ciclos (ele pode transferir dados e tornar o teste mais intrusivo):

```bash
./monitorar_claro_macos.sh --network-quality-every 1
```

Para desativá-lo:

```bash
./monitorar_claro_macos.sh --network-quality-every 0
```

Interrompa com `Ctrl-C` se necessário. O script grava o resumo parcial antes de encerrar.

## Resultados

Sem `--output-dir`, uma pasta como `claro-monitor-20260822-213000/` é criada no diretório atual.

| Arquivo | Conteúdo |
| --- | --- |
| `medicoes.csv` | Uma linha por alvo de ping e ciclo, com perda, latência e jitter. |
| `dns.csv` | Consultas DNS pelo sistema e pelo `1.1.1.1`, com transporte UDP/TCP e tempo de consulta. |
| `https.csv` | Status HTTP, tempo de resolução, conexão/primeiro byte/total e IP remoto; inclui teste `pinned_ipv4`, sem DNS. |
| `networkquality.csv` | Capacidades, responsividade e latência ociosa coletadas pelo `networkQuality`. |
| `eventos.log` | Ciclos executados e alertas de degradação ou falha. |
| `resumo.txt` | Consolidação final para leitura rápida. |
| `networkquality/` | Saída bruta de cada execução de `networkQuality`, quando aplicável. |

## Como interpretar

- Falha ou perda no gateway e também nos destinos externos aponta para o enlace local, modem, sinal/coaxial, CMTS ou rede da operadora.
- Gateway estável e problemas apenas nos destinos externos sugerem falha após o primeiro salto ou em rotas externas.
- HTTPS `hostname` falho, mas `pinned_ipv4` bom, isola a falha para DNS. Se ambos falharem, o problema é conexão TCP, rota ou aplicação — não apenas DNS.
- HTTPS IPv4 normal e IPv6 falho isola a investigação para IPv6.
- Compare os horários de alertas com os dados de `networkQuality`. Boa capacidade nominal não impede latência alta sob carga; responsividade e RTT ajudam a evidenciar esse caso.

O ICMP pode ser tratado com prioridade menor por algumas redes. Por isso, a conclusão deve considerar todos os sinais, principalmente HTTPS e DNS, e não apenas o ping.

## Privacidade e versionamento dos resultados

Os resultados não são versionados por padrão. Eles podem revelar IP público, horário de uso, resolvedores, IPs remotos e características da conexão. O `.gitignore` exclui as pastas de execução produzidas pelo script e a pasta `resultados/`.

Se for útil anexar um caso a uma issue ou compartilhar com o suporte, prefira exportar uma cópia revisada, removendo IPs públicos e dados pessoais. Amostras deliberadamente anonimizadas podem ser guardadas em `examples/`.

## Limitações

- O monitor não mede sinal DOCSIS, níveis de potência, SNR ou erros do modem; esses dados dependem da interface do equipamento/operadora.
- Testes de velocidade no navegador podem divergir porque usam servidores, rotas e métodos diferentes.
- O diagnóstico fica mais confiável quando feito com somente o Mac ligado diretamente ao modem, sem roteadores ou access points intermediários.

## Contribuições

Issues e melhorias são bem-vindas. Ao reportar um problema, inclua a versão do macOS, o comando usado e um trecho anonimizado dos arquivos de resultado.
