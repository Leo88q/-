// SPDX-License-Identifier: MIT
// Warren Protocol — architecture SPECIFICATION, NOT production code. Not compiled, not audited.
pragma solidity ^0.8.26;

import {ImmutableCore} from "./ImmutableCore.sol";

/// @title GenotypeLib
/// @notice Детерминированная генетика карликовых кроликов: 6 локусов × 2 аллеля + флаги.
///         Результат выводится из генотипов родителей и соли выводка — без оракула
///         случайности, без «руки оператора», проверяемо офчейн (см. docs/06).
library GenotypeLib {
    uint8 internal constant ALLEL_MUTANT = 15;
    uint8 internal constant ALLEL_SUBRARE = 14;

    /// @dev ДВА аллеля на локус (2 × uint8 = uint16), упаковано по 6 локусов.
    struct Genotype {
        uint16 coat;         // 0 angora-mini .. 15 mutant
        uint16 color;        // agouti > shaded > chinchilla > pointed > self > broken
        uint16 conformation; // compact | cobby | long | muscular | fine-boned
        uint16 eyes;         // brown | blue | ruby | hetero | amber
        uint16 temperament;  // bold > curious > calm > velcro > shy
        uint16 vitality;     // robust > steady > sensitive (sensitive рецессивен)
        bytes8 flags;        // BINKY,FLOPPY,LONGEVITY,STREAMSTAR,WHISPER,FERTILITY,
                             // SHOWQUALITY,SENIORGRACE,TINKER,NOCTURNAL + MOON_CHIN
    }

    struct RarityInput {
        uint16 phenotypeScore;  // 0..1000 — редкость выраженного фенотипа
        uint16 homozygosity;    // 0..1000
        uint16 pedigreeScore;   // 0..1000 — глубина/титулы/полнота герба
        uint16 lineageAura;     // 0..1000 — Legacy-медали, Golden Carrot, sanctuary-подвиги
        uint16 careBonus;       // 0..100  — забота о родителях (docs/06.5)
        uint16 inbreedingBps;   // 0..10000 (F × 10 000)
    }

    /// @notice Выбор аллеля родителем: детерминирован по хешу.
    function _pick(uint16 locus, bytes32 h, uint8 lane) internal pure returns (uint8) {
        uint8 bit = uint8(uint256(h) >> (lane * 8)) & 1;
        return bit == 0 ? uint8(locus >> 8) : uint8(locus & 0xff);
    }

    function _cross(uint16 a, uint16 b, bytes32 h, uint8 lane) internal pure returns (uint16) {
        return (uint16(_pick(a, h, lane)) << 8) | uint16(_pick(b, h, lane ^ 1));
    }

    /// @notice Кроссинговер (12%) + мутация (1.8% на локус) применяются к потомку.
    function inherit(
        Genotype memory sire,
        Genotype memory dam,
        bytes32 litterSalt
    ) internal pure returns (Genotype memory child) {
        bytes32 h = keccak256(abi.encode(sire, dam, litterSalt));
        uint256 x = uint256(h);

        child.coat = _cross(sire.coat, dam.coat, h, 0);
        child.color = _cross(sire.color, dam.color, h, 1);
        child.conformation = _cross(sire.conformation, dam.conformation, h, 2);
        child.eyes = _cross(sire.eyes, dam.eyes, h, 3);
        child.temperament = _cross(sire.temperament, dam.temperament, h, 4);
        child.vitality = _cross(sire.vitality, dam.vitality, h, 5);

        // crossover coat↔color (12%)
        if (x % 100 < 12) {
            (child.coat, child.color) = (child.color, child.coat);
        }
        // mutation 1.8% на локус
        for (uint8 i; i < 6; ++i) {
            if ((x >> (i * 3)) % 1000 < 18) {
                _mutate(child, i, x);
            }
        }
        // особые гены: OR с 20% «тихого носительства», 0.4% — новый мутант
        bytes8 fs = sire.flags | dam.flags;
        child.flags = (x >> 96) % 100 < 20 ? fs & bytes8(~(uint64(1) << (x % 8))) : fs;
    }

    function _mutate(Genotype memory g, uint8 locus, uint256 x) private pure {
        uint8 mutant = x % 500 == 0 ? ALLEL_MUTANT : ALLEL_SUBRARE;
        if (locus == 0) g.coat = (uint16(mutant) << 8) | (g.coat & 0xff);
        else if (locus == 1) g.color = (uint16(mutant) << 8) | (g.color & 0xff);
        else if (locus == 2) g.conformation = (uint16(mutant) << 8) | (g.conformation & 0xff);
        else if (locus == 3) g.eyes = (uint16(mutant) << 8) | (g.eyes & 0xff);
        else if (locus == 4) g.temperament = (uint16(mutant) << 8) | (g.temperament & 0xff);
        else g.vitality = (uint16(mutant) << 8) | (g.vitality & 0xff);
    }

    /// @notice Выраженный аллель по таблице доминирования (упрощённо: максимум аллелей).
    function expressed(uint16 locus) internal pure returns (uint8) {
        uint8 a = uint8(locus >> 8);
        uint8 b = uint8(locus & 0xff);
        return a >= b ? a : b;
    }

    /// @notice 0.35·pheno + 0.20·homozyg + 0.20·pedigree + 0.15·aura + 0.10·care − 0.30·inbreeding
    /// @dev Штраф инбридинга нелинейный: (F/MAX)^2. Тир ограничивается Epic при F ≥ 6.25%.
    function rarity(RarityInput memory i, uint16 inbreedingCapBps) internal pure returns (uint16 score, uint8 tier) {
        uint256 penalty = (uint256(i.inbreedingBps) * 1e4) / ImmutableCore(0).MAX_INBREEDING_BPS();
        penalty = (penalty * penalty) / 1e4; // квадратично
        int256 raw = (int256(35 * i.phenotypeScore) + int256(20 * i.homozygosity)
                    + int256(20 * i.pedigreeScore) + int256(15 * i.lineageAura)
                    + int256(10 * i.careBonus) - int256(30 * penalty)) / 100;
        if (raw < 0) raw = 0;
        if (raw > 1000) raw = 1000;
        if (i.inbreedingBps >= 625 && raw > 799) raw = 799;   // cap Epic при родстве
        score = uint16(raw);
        tier = score >= 930 ? 5 : score >= 800 ? 4 : score >= 650 ? 3 : score >= 500 ? 2 : score >= 350 ? 1 : 0;
    }

    /// @notice Wright's coefficient по Merkle-дереву предков (4 колена) — вызывается из PedigreeLib.
    /// @dev Здесь только «суммарный» расчёт: F = Σ (1/2)^(n1+n2+1) (1+FA). Полная реализация —
    ///      офчейн-сервис + on-chain верификация корня.
    function inbreedingBps(uint256 sharedPathsWeight) internal pure returns (uint16) {
        return uint16(sharedPathsWeight > 10_000 ? 10_000 : sharedPathsWeight);
    }
}
