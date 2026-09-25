# Siding Scanner POC: resumo da semana (25/09 a 01/10/2026)

**Objetivo:** levantamento de siding (área líquida de parede, cantos, aberturas) em minutos, no local, com margem de erro calibrada (cerca de ±5 %), usando a pose do ARKit como dada (D1) e **ajuste de planos por RANSAC em tempo real** (D3). Aparelhos de captura: iPhone 13 (sem LiDAR) e 13 Pro.

---

## 1. O que construímos

| Peça | O que faz |
|---|---|
| **SidingsAR** (app iOS) | Planos nativos do ARKit com deduplicação (NMS), suavização e marcadores; HUD com fps, memória, exposição e ISO |
| **Gravador Plane Lab** (no app) | Grava, por frame, pose, intrínsecos e feature points, mais vídeo HEVC 1440p60, âncoras do ARKit e eventos. Também grava a **nuvem média ao vivo** (o acumulador da CurvSurf portado para Swift), **fotos 4032 × 3024 com pose** e um **teto de exposição de 1 ms**. Formato versionado: v1 → v2 (nuvem) → v3 (planos do X1) |
| **Plane Lab** (Python + Blender, no Mac) | Leitor; `planelab info` e `peek` (cópia legível do banco); `pull.sh` (do iPhone ao Blender num comando); sessões sintéticas; extensão do Blender com câmera e vídeo, pontos brutos, nuvem média em 3 objetos (rosa < 10 amostras, magenta 10–49, vermelho 50+), planos do ARKit, planos do X1 e Pick Point |
| **Testes** | Swift 163, Python com 98 % de cobertura, suíte headless do Blender. Fixtures de contrato Swift ↔ Python para os schemas v1, v2 e v3 |

## 2. O que aprendemos sobre o ARKit e os dados

- **O fps segue a temperatura:** 60 Hz com o aparelho frio, 30 Hz quente. Medir o tempo sempre por `ARFrame.timestamp`.
- **Gravar tudo é barato:** cerca de 82 MB/min, sem frames perdidos, cópia da imagem em menos de 1 ms.
- **Os intrínsecos mudam com o foco** (fx de 1524 a 1527 px): ler por frame, nunca como constante.
- **Ruído:** o mesmo feature oscila 2,5–3 cm RMS perto da câmera. Ao ar livre há pontos até 16–22 m, mas além de 10 m espalham cerca de 30 cm.
- **A parede lisa quase não dá pontos.** Eles caem em bordas, textura, ACs e grades.
- **A classificação do ARKit ao ar livre não serve:** todo plano horizontal virou "seat".
- **Fotos:** o que limita é o borrão, não a resolução. 9,4 ms de exposição deram cerca de 14 px de borrão; com teto de 1 ms ficou em cerca de 1,8 px, e o tracking continuou 100 % normal.
- **Limite físico dos dados:** a 4–7 m, cada superfície é uma "fatia" de pontos com **30–40 cm de espessura** (erro de profundidade em forma de agulha). O offset de um plano é bom a cerca de ±15–20 cm a essa distância. Para área, o que importa são as bordas.

## 3. Experimentos de ajuste de planos

### X1: FindSurface (CurvSurf, proprietário) mais o nosso rastreamento, ao vivo no iPhone

- **O FindSurface:** biblioteca fechada que faz crescimento de região a partir de uma semente, com mínimos quadrados de distâncias ortogonais. Só roda em iOS e Linux e é **só para uso não comercial**. O app de demonstração "pisca por design": refaz o ajuste do zero a cada frame.
- **O que construímos em volta:**
  - sementes automáticas, das células mais planas primeiro;
  - rastreador que casa ajustes pelos IDs de feature compartilhados, com estados tentativo → confirmado → obsoleto e fusões;
  - gravação dos planos (schema v3) e camada no Blender;
  - "dials" ajustáveis ao vivo no menu Debug, com cada mudança registrada como evento.
- **Dials v2:** distância média 0,5 → 1,0 m, extensão lateral 5 → 7, raio máximo da semente 3 → 6 m, faixa de retenção 5 → 15 cm, mais um merge gap novo de 0,5 m.
- **Resultados:**

  | Gravação | O que achou |
  |---|---|
  | `115808` (v1) | Chão e fachada certos, mas a fachada **parou em 7,7 × 5,4 m** |
  | `142809` (v2) | Fachada de **18,3 × 8,5 m**, a 0,4° da vertical, RMS 6,5 cm, estável por 103 s |

  Problemas nas duas rodadas v2 (`142809` e `143156`):
  - **3 a 5 planos inclinados falsos** por rodada (8–58°): não há como impor vertical ou horizontal;
  - **cerca de 13 de 20 planos piscando** por 1–8 s;
  - **área cerca de 2,3× maior** que a nuvem real, porque o convex hull pega pontos soltos;
  - caixa-preta: não dá para corrigir por dentro.
- **Veredito:** é um baseline útil, **não é o pipeline**.

### Sonda RANSAC (numpy, rascunho fora do T17)

- **Só planos verticais e horizontais**, e **nenhum plano inclinado** nas 3 gravações. Encontrou a mesma fachada e a parede próxima que o X1 ajustou três vezes, inclinada (RMS 2 cm).
- **Expôs dois problemas a resolver:**
  - **fatias:** a fachada saiu em 3–4 planos paralelos, o chão em 3;
  - **pontos coplanares distantes** inflando a extensão (uma "parede" de 26 m).
- **Visual:** `lab/ransac_probe.blend` (cena estática) e **`lab/ransac_replay.blend`** (RANSAC a cada 10 s sobre o vídeo, ao lado do X1).

### RANSAC em tempo real? Sim (medido)

Swift `-O`, um núcleo do M2 Max, nuvem real de 10.912 pontos:

| Busca | Tempo | Planos |
|---|---|---|
| Orçamento fixo de tentativas | 160 ms | 10 |
| **k adaptativo** (para com 99 % de confiança) | **25,6 ms** | 10 |
| k adaptativo, top 3 | **4,5 ms** | 3 |

Com o rastreamento incremental (refazer só os planos conhecidos e buscar só nos pontos livres), a maioria das rodadas deve custar poucos milissegundos. O custo é O(k · N) por plano, e k cresce com w⁻ˢ, por isso as restrições vertical/horizontal (s = 2 ou 1) também aceleram.

### X2: RANSAC nosso, que é o próximo passo (desenho do `EXPERIMENTS.md`, XD12)

Esqueleto Efficient RANSAC:
- só verticais e horizontais;
- amostragem local (NAPSAC) com pontuação preguiçosa;
- PROSAC pela contagem de amostras (os pontos vermelhos primeiro);
- MSAC com faixa por ponto que cresce com a distância (cerca de 3× a da SPEC a distância);
- rejeição de amostras colineares;
- refinamento LO;
- **partes conexas** por plano e **extensões robustas** (percentis ou grade, nunca o convex hull);
- **fusão das fatias**;
- o rastreador com as lições do X1;
- rodadas incrementais.

**Critério para vencer o X1:** nenhum plano inclinado, no máximo um plano por parede, extensão a ±20 % de onde estão os pontos, IDs estáveis.

## 4. Bugs e lições de processo

- **F3 (Reload Scripts) do Blender só recarregava o arquivo principal da extensão.** Um Blender aberto antes do schema v3 recusava as gravações novas em silêncio. Corrigido: o F3 recarrega tudo, o erro vai para `planelab.log` e para o painel.
- **Seed na célula mais densa caía em cantos** e gerava planos diagonais. Corrigido: sementes das células **mais planas** primeiro.
- **A distância "coplanar" pela normal de um plano só** exagera para planos grandes. Corrigido: usar a normal média.
- Sempre que possível, **medir em vez de supor**: o benchmark e a sonda estão salvos em `PlaneLab/spikes/x1_vs_ransac/`.

## 5. Onde estamos e o que vem

- **Branches:**
  - `main`: o Plane Lab até 30/09;
  - `exp/x1-findsurface-live`: o X1 completo, mais o schema v3 e as correções do Blender;
  - **`exp/x2-ransac`** (atual, derivado do X1).
- **Próximo:**
  - **T17** (modelos RANSAC), T18 (partes e extensões), T19 (rastreador), T20 (pipeline e `run`/`export`), depois a camada do Blender e a comparação nas gravações `115808`, `142809` e `143156`.
  - Em paralelo, o T33: COLMAP nas fotos de alta resolução, na máquina Linux com NVIDIA.
- **Pendências do usuário:**
  - teste de scrub do T2 e checagem do Pick Point;
  - E2 por parede (T24) quando os nossos planos aparecerem;
  - gravação do local com 10–15 m de distância livre (T25);
  - medir no iPhone o tempo real do RANSAC.
- **Riscos:** o ruído de 30–40 cm de profundidade a 4–7 m limita o offset, não a área; a parede lisa dá poucos pontos; um FindSurface comercial exigiria licença.

**Documentos-chave:**
- `EXPERIMENTS.md`: X1, X2, veredito e decisões XD1–XD13;
- `SPEC.md`: Plane Lab, decisões L e P, tarefas;
- `CONSOLIDATION.md`: produto, D1–D7 e achados §10b;
- `HANDOFF.md`: estado e fatos aprendidos;
- `REMAINING.md`: o que falta.
