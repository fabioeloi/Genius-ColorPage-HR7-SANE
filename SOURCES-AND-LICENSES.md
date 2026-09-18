# Fontes, integridade e licenças

O manifesto de máquina está em manifest.json. Os hashes SHA-256 são conferidos antes de qualquer compilação ou execução do artefato correspondente.

| Componente | Origem | Licença |
| --- | --- | --- |
| sane-backends 1.4.0 | projeto SANE, tag oficial 1.4.0 no GitLab | GPL-2.0-or-later |
| XSane 0.999 | fonte original publicada pelo projeto XSane; espelho BLFS, pois a página de download do XSane está temporariamente indisponível | GPL-2.0-or-later |
| Zadig 2.9 / libwdi 1.5.1 | release oficial pbatard/libwdi | GPL-3.0-or-later (Zadig), LGPL-3.0-or-later (libwdi) |
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

## Candidatos para as APIs Windows (ainda não redistribuídos)

| Componente | Origem/versão avaliada | Licença | Situação |
| --- | --- | --- | --- |
| WiaSane | https://github.com/mback2k/wiasane; alpha 0.1.2.10 (2016-10-08) | MIT-style notice; `sane.h` tem aviso separado de domínio público | O upstream descreve builds/testes com Windows 7, Visual Studio 2012 e WDK 8. O instalador oficial não pôde ser obtido: o host apresentou certificado TLS para outro nome. Não foi executado; Windows 10/11 e x64 continuam sem prova. É necessário obter uma cópia verificável ou manter bloqueada a promessa WIA. |
| SANEWinDS x64 | https://sourceforge.net/projects/sanewinds/files/; 1.6.9221 (2025-04-02) | GPL-3.0-only | MSI oficial baixado e hash fixado em `manifest.json`; MSI não tem assinatura Authenticode. Código-fonte correspondente: commit `6b6a9f3dada85372e3795b21dad6ccec65d9e8ee`. Enumeração e aquisição TWAIN ainda precisam de teste. |
| SANEWinDS x86 | https://sourceforge.net/projects/sanewinds/files/; 1.6.9221 (2025-04-02) | GPL-3.0-only | MSI oficial baixado e hash fixado em `manifest.json`; MSI não tem assinatura Authenticode. Código-fonte correspondente: commit `6b6a9f3dada85372e3795b21dad6ccec65d9e8ee`. Enumeração e aquisição TWAIN ainda precisam de teste. |

Esses componentes continuam fora do instalador atual até as provas de API e a revisão de redistribuição. A distribuição de SANEWinDS deve preservar `LICENSE.txt` e os avisos/componentes indicados pelo código correspondente, incluindo `ReadMe_NLog.txt` e a origem do sample TWAIN modificado. A revisão e o pacote de código-fonte completo são pré-requisitos para a release; o link do commit sozinho não substitui esse pacote.

O `saned` incluído no SANE 1.4.0 aceita `-l` (standalone), `-b` (endereço de bind) e `-p` (porta). O build local confirmou a existência do daemon e um teste de socket comprovou que `-b 127.0.0.1` escuta somente em loopback. No código do `saned`, o socket separado de dados é ligado ao endereço local do socket de controle aceito. O serviço do produto fixa `127.0.0.1:6566`, instala uma ACL com somente `127.0.0.1` e não cria regra de firewall. Isso ainda não é uma prova de aquisição WIA/TWAIN.

- Código SANEWinDS (commit exato): https://sourceforge.net/p/sanewinds/code/ci/6b6a9f3dada85372e3795b21dad6ccec65d9e8ee/tree/

## Evidência local de viabilidade no Windows

No Windows 10 Home 22H2 x64 (build 19045), o serviço `GeniusColorPage-HR7-SANE` foi registrado como automático e iniciado. A tabela de sockets mostrou exatamente um listener do serviço: `127.0.0.1:6566`. `Windows/tests/Test-SanedLoopback.ps1 -Port 16566` aceitou uma conexão IPv4 local, não expôs endereço wildcard e removeu o processo temporário; depois do teste, permaneceu somente o listener de produção em loopback. Nenhuma regra de firewall foi criada. O log avisa que o alias textual `sane-port` não existe na tabela de serviços do Cygwin, mas confirma que o daemon iniciou usando a porta numérica configurada.

Os MSIs SANEWinDS 1.6.9221 x64 e x86 foram instalados para avaliação depois da conferência dos hashes do manifesto. Ambos são `NotSigned`; os data sources `SANEWinCDS64.ds` e `SANEWinCDS32.ds` foram encontrados, respectivamente, em `C:\Windows\twain_64\SANEWinDS` e `C:\Windows\twain_32\SANEWinDS`. Isso comprova a instalação dos arquivos TWAIN, não a enumeração por um aplicativo cliente nem a aquisição de uma página. O driver USB do scanner não foi alterado nesta retomada. A WIA continua bloqueada pela indisponibilidade de um binário upstream com transporte TLS verificável.
