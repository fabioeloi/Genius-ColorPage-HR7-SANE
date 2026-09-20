# Fontes, integridade e licenças

O manifesto de máquina está em manifest.json. Os hashes SHA-256 são conferidos antes de qualquer compilação ou execução do artefato correspondente.

| Componente | Origem | Licença |
| --- | --- | --- |
| sane-backends 1.4.0 | projeto SANE, tag oficial 1.4.0 no GitLab | GPL-2.0-or-later |
| XSane 0.999 | fonte original publicada pelo projeto XSane; espelho BLFS, pois a página de download do XSane está temporariamente indisponível | GPL-2.0-or-later |
| Zadig 2.9 / libwdi 1.5.1 | release oficial pbatard/libwdi | GPL-3.0-or-later (Zadig), LGPL-3.0-or-later (libwdi) |
| Microsoft Windows-driver-samples WIA 2.0 (`wiadriverex`) | commit `3c3fb49073c047c4cc8e6c203c6331f62b426507`, adapted in `Windows/WIA2/` | MS-PL; retain the full license and attribution notices if source or binaries are redistributed |
| Cygwin | cygwin.com | vários; o setup valida o catálogo setup.ini.sig e os pacotes |
| sane-backends e Simple Scan no macOS | fórmulas oficiais Homebrew | GPL-2.0-or-later e GPL-3.0-or-later |

Links de código-fonte:

- https://gitlab.com/sane-project/backends
- https://gitlab.com/sane-project/frontend/xsane
- https://github.com/pbatard/libwdi
- https://www.cygwin.com/
- https://github.com/Homebrew/homebrew-core
- https://gitlab.gnome.org/GNOME/simple-scan

O arquivo de SANE empregado no Windows é a tag 1.4.0 do projeto, não um snapshot de branch. A opção de compilação BACKENDS=plustek produz somente esse backend. XSane é mantido em fonte separada e é compilado contra a cópia privada do SANE.

Para Cygwin e Homebrew, o gerenciador é o verificador de transporte: Cygwin verifica o catálogo assinado e os pacotes; Homebrew valida os SHA-256 declarados na fórmula/bottle. O instalador registra as versões de Cygwin/Homebrew realmente obtidas para auditoria. Não aceita um executável Zadig sem hash e assinatura Authenticode válidos.

## APIs Windows e instalador em desenvolvimento

| Componente | Origem/versão avaliada | Licença | Situação |
| --- | --- | --- | --- |
| WiaSane | https://github.com/mback2k/wiasane; commit `cb38cb469e4dbaed771806d5ca2606baa3086e20` | MIT-style notice; `sane.h` tem aviso separado de domínio público | O código foi recuperado do GitHub por TLS, mas implementa um microdriver WIA legado e usa um projeto Visual Studio 2012/WDK 8. Não é o provedor WIA 2.0 selecionado; nenhum binário foi instalado ou testado. |
| WINSANE SANE-network client subset | Mesmo commit WiaSane acima; `Windows/WIA2/thirdparty/winsane/` e `winsane-util/` | Aviso permissivo de Marc Hoersken; `sane.h` tem aviso separado de domínio público | Somente a biblioteca cliente C++ de protocolo SANE é reutilizada pelo provedor WIA 2.0 novo; o microdriver WiaSane continua fora da arquitetura selecionada. Preserve `COPYING-WINSANE.txt` e a revisão/hash de origem ao redistribuir. |
| Microsoft WIA 2.0 `wiadriverex` | https://github.com/microsoft/Windows-driver-samples/tree/3c3fb49073c047c4cc8e6c203c6331f62b426507/wia/wiadriverex | MS-PL | Adaptado em fonte para transferir imagens do SANE por loopback e instalar um dispositivo de software. Não compilado ou instalado: WIA enumeração/aquisição ainda não foram provadas e não há binário redistribuível. |
| SANEWinDS x64 | https://sourceforge.net/projects/sanewinds/files/; 1.6.9221 (2025-04-02) | GPL-3.0-only | MSI oficial baixado, SHA-256 fixado em `manifest.json`, mas sem assinatura Authenticode. A fonte TWAIN enumerou/abriu e passou aquisição Color x64 de página inteira e Gray preview x64 por transferências native/memory. A redistribuição ainda depende da fonte correspondente completa, avisos e revisão. |
| SANEWinDS x86 | https://sourceforge.net/projects/sanewinds/files/; 1.6.9221 (2025-04-02) | GPL-3.0-only | MSI oficial baixado, SHA-256 fixado em `manifest.json`, mas sem assinatura Authenticode. A fonte TWAIN enumerou/abriu e passou aquisição Gray preview x86 por transferências native/memory. A redistribuição ainda depende da fonte correspondente completa, avisos e revisão. |
| Bundle WiX Burn e helpers nativos | `Windows/Installer/` e `Windows/WIA2/Installer/` | Fontes WiX e dos helpers estão neste repositório; libwdi é usada dinamicamente sob LGPL-3.0-or-later | A fonte do instalador existe, mas nenhum artefato GUI foi compilado ou instalado. A release exige revisão da fonte/avisos do libwdi e aprovação dos materiais de conformidade. O libwdi pode instalar certificado específico do dispositivo compartilhado com outros dispositivos que o utilizem; o uninstall não remove esse certificado compartilhado. |

Ainda não existe um instalador redistribuível gerado. A distribuição de SANEWinDS deve preservar `LICENSE.txt` e os avisos/componentes indicados pelo código correspondente, incluindo `ReadMe_NLog.txt` e a origem do sample TWAIN modificado. O pacote de código-fonte completo e a revisão de redistribuição são pré-requisitos para a release; o link do commit sozinho não substitui esse pacote. O helper de build exige aprovação explícita e marca builds privados como avaliação.

O `saned` incluído no SANE 1.4.0 aceita `-l` (standalone), `-b` (endereço de bind) e `-p` (porta). O build local confirmou a existência do daemon e um teste de socket comprovou que `-b 127.0.0.1` escuta somente em loopback. No código do `saned`, o socket separado de dados é ligado ao endereço local do socket de controle aceito. O serviço do produto fixa `127.0.0.1:6566`, instala uma ACL com somente `127.0.0.1` e não cria regra de firewall. Isso ainda não é uma prova de aquisição WIA/TWAIN.

- Código SANEWinDS (commit exato): https://sourceforge.net/p/sanewinds/code/ci/6b6a9f3dada85372e3795b21dad6ccec65d9e8ee/tree/

## Evidência local de viabilidade no Windows

No Windows 10 Home 22H2 x64 (build 19045), o serviço `GeniusColorPage-HR7-SANE` foi registrado como automático e iniciado. A tabela de sockets mostrou exatamente um listener do serviço: `127.0.0.1:6566`. `Windows/tests/Test-SanedLoopback.ps1 -Port 16566` aceitou uma conexão IPv4 local, não expôs endereço wildcard e removeu o processo temporário; depois do teste, permaneceu somente o listener de produção em loopback. Nenhuma regra de firewall foi criada. O log avisa que o alias textual `sane-port` não existe na tabela de serviços do Cygwin, mas confirma que o daemon iniciou usando a porta numérica configurada.

Os MSIs SANEWinDS 1.6.9221 x64 e x86 foram instalados para avaliação depois da conferência dos hashes do manifesto. Ambos são `NotSigned`; os data sources `SANEWinCDS64.ds` e `SANEWinCDS32.ds` foram encontrados, respectivamente, em `C:\Windows\twain_64\SANEWinDS` e `C:\Windows\twain_32\SANEWinDS`. Isso comprova a instalação dos arquivos TWAIN, não por si só a enumeração ou a aquisição por aplicativo; evidências TWAIN posteriores estão em `Windows/API-TEST-PLAN.md`. O driver físico USB permanece associado ao WinUSB. `WIA.DeviceManager` retornou zero dispositivos; WiaSane é um microdriver legado não selecionado. O sample WIA 2.0 da Microsoft foi adaptado em fonte e o WINSANE client foi integrado, mas ainda não houve compilação ou instalação. A tentativa de instalar o toolchain do WDK parou na confirmação UAC (erro 1602), portanto não existe build WIA verificado nesta máquina.
