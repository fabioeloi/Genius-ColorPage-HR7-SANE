# Genius ColorPage-HR7 — pacote SANE aberto

Este pacote instala uma rota de digitalização livre, limitada ao Genius ColorPage HR7 cujo ID USB é exatamente 0458:2013. O backend SANE usado é plustek. A lista de dispositivos do projeto SANE classifica esse modelo como Complete.

O pacote não contém nem instala o driver proprietário antigo do scanner. Esse driver é de outra geração do Windows; este pacote usa SANE + libusb/WinUSB no Windows e SANE + libusb no macOS.

## Antes de começar

- Com a alimentação desconectada, coloque a trava de transporte em UNLOCK. No HR7 testado, ela fica no painel traseiro, acima do conector USB. Deixe o scanner montado e apoiado em uma superfície firme e plana.
- Conecte somente o HR7 diretamente a uma porta USB durante a associação de driver.
- No Windows, a associação a WinUSB substitui o driver que estiver associado somente a esse scanner. Isso pode impedir o uso do software proprietário enquanto estiver ativa.
- Feche qualquer aplicativo de digitalização antes da instalação.
- É necessário internet. Não há downloader de drivers comerciais nem desativação de assinatura de drivers.

## Windows 10/11 x64

Abra PowerShell como administrador, entre na pasta Windows deste pacote e execute:

    Set-ExecutionPolicy -Scope Process Bypass
    .\Install-Windows.ps1

O instalador confirma a edição x64 do Windows e exige um único dispositivo presente cujo ID seja USB\VID_0458&PID_2013. Ele registra o driver existente em ProgramData, tenta criar um ponto de restauração e baixa somente os itens descritos em ../manifest.json.

Quando a janela do Zadig abrir:

1. Abra Options > List All Devices.
2. Selecione somente a entrada cujo USB ID mostrado seja 0458:2013.
3. Escolha WinUSB e clique Install Driver.
4. Feche o Zadig e retorne ao instalador.

Não use Create New Device. Não escolha hubs, teclado, mouse, armazenamento USB ou qualquer linha com outro ID.

Ao terminar, execute o atalho “Genius ColorPage HR7 Scan” criado na área de trabalho pública, ou Windows\Launch-XSane.ps1. O primeiro lançamento inicia o Cygwin/X e depois o XSane.

O build Windows usa leitores pthread, com o ajuste específico do Cygwin necessário ao SANE 1.4.0: o leitor USB permanece no mesmo processo. Nesta máquina, o build anterior com `fork` travava antes da calibração. O script também reconfigura builds antigos que ainda não habilitam pthread.

Diagnóstico sem modificar driver:

    .\Diagnose-Windows.ps1

Ele grava um log limitado a versão, arquitetura, ID do HR7 e saída SANE em ProgramData\GeniusColorPage-HR7-SANE\logs.

## macOS Tahoe (26) Apple Silicon

No Finder, dê duplo clique em macOS/Install-macOS.command. Caso o macOS bloqueie o arquivo baixado, abra o Terminal na pasta do pacote e execute:

    chmod +x macOS/*.command
    ./macOS/Install-macOS.command

O instalador exige macOS 26 ou superior em arm64 e exatamente um HR7 conectado, com ID USB 0458:2013. Ele usa Homebrew para instalar sane-backends 1.4.0 e Simple Scan 50.0, conferindo a versão efetivamente instalada. O Homebrew valida os hashes dos bottles definidos nas fórmulas. Se Homebrew ainda não estiver instalado, o script mostra a URL oficial e pede a confirmação literal YES antes de chamar seu instalador.

O lançador macOS/Launch-ColorPage-HR7.command define SANE_CONFIG_DIR apenas para seu processo. Assim, dll.conf e plustek.conf privados não alteram a instalação global de SANE.

Antes de abrir o Simple Scan, rode macOS/Diagnose-macOS.command. O log é salvo em ~/Library/Application Support/GeniusColorPage-HR7-SANE/logs e registra a detecção USB e as saídas de sane-find-scanner e scanimage -L.

## Teste de aceitação

Faça este teste com o scanner ligado diretamente por USB:

1. Rode o diagnóstico da plataforma e confirme que ele mostra 0458:2013.
2. Confirme que sane-find-scanner encontra o USB e que scanimage -L lista o dispositivo.
3. Abra XSane no Windows ou Simple Scan pelo lançador no macOS.
4. Faça Preview, selecione Color e 300 dpi, digitalize uma página e salve PNG ou TIFF.
5. No Windows, reinicie e abra o atalho novamente.

Confirme que o carro se desloca suavemente e retorna, e que o arquivo mostra o conteúdo impresso. Um PNG válido ou código de saída zero não comprova o funcionamento: com a trava fechada, os testes retornaram apenas uma imagem branca com ruído. O aquecimento inicial da lâmpada pode levar cerca de um minuto antes da digitalização.

Uma falha de detecção não aciona troca para outro backend ou driver. Cole o log de diagnóstico ao pedir ajuda.

## Desinstalação e reversão

Windows:

    .\Uninstall-Windows.ps1

O desinstalador encerra somente processos XSane iniciados pelo pacote, remove seu runtime privado e o atalho. Ele não apaga automaticamente um INF do Driver Store nem tenta adivinhar o driver anterior. Use Device Manager para escolher o driver registrado em ProgramData\GeniusColorPage-HR7-SANE\state.json, ou restaure o ponto de restauração que o instalador tentou criar.

macOS:

    ./macOS/Remove-macOS.command

Por padrão, isso remove somente configurações, lançador e logs locais. Use --remove-brew-packages somente se esses dois pacotes não forem usados por outro scanner.

## Limitações conhecidas

- O pacote atual ainda não é instalador para usuário final e exige associação manual do driver. A aquisição TWAIN está verificada em clientes x86/x64 para prévia Gray por transferência native e memory, e em x64 para página inteira Color native. Não há provedor WIA verificado, portanto aplicativos exclusivamente WIA ainda não descobrem o HR7. O WHW registra as evidências WIA que faltam e a substituição do fluxo com scripts/Zadig por um instalador GUI assinado.
- A associação WinUSB é experimental e reversível, porém depende do estado do Driver Store do computador.
- XSane 0.999 é uma interface gráfica legada; ela é usada aqui porque funciona com SANE no Cygwin/X. O backend e o ID USB continuam fixados no runtime privado.
- Em 17/09/2026, testes físicos no Windows capturaram uma página de teste HP em 75 dpi e uma página inteira em 150 dpi pela instalação padrão SANE 1.4.0 com pthread. As imagens contêm texto e ilustrações reconhecíveis; o usuário confirmou deslocamento completo e retorno suave do carro. XSane e o macOS não foram testados fisicamente aqui. O diagnóstico e os logs estão registrados em Windows/DIAGNOSTIC-STATUS-20260916.md.

Consulte manifest.json e SOURCES-AND-LICENSES.md para versões, hashes, licenças e URLs.
