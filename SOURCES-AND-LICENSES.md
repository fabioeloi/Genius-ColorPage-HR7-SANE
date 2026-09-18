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
| WiaSane | https://github.com/mback2k/wiasane; alpha 0.1.2.10 (2016) | MIT; o cabeçalho `sane.h` traz aviso de domínio público separado | Código está disponível; upstream informa testes no Windows 7. Precisa de prova em Windows 10/11, arquitetura x64 e revisão do instalador antes de redistribuir. |
| SANEWinDS | https://sourceforge.net/projects/sanewinds/files/; 1.6.9221 x86/x64 (2025-04-02) | GPL-3.0 | Builds x86/x64 publicados. Antes de incorporar, fixar downloads/hashes e fornecer código-fonte correspondente, avisos e modificações conforme a licença. |

Esses candidatos não fazem parte do instalador atual nem do manifesto de componentes verificáveis. Somente serão adicionados ao `manifest.json` depois de baixar cada artefato versionado, confirmar hash, revisar assinatura e registrar a origem exata do código-fonte.
