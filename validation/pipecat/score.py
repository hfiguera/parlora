"""Offline scoring of observed captions. No model calls, retries, or LLM judge."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import unicodedata
from numeric_score import VERSION as NUMERIC_VERSION, compare as numeric_compare


def words(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    # Preserve apostrophes and digits. Do not normalize away numbers or negations.
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text, flags=re.UNICODE)


def errors(reference, hypothesis):
    """Levenshtein word distance, pooled later by reference word count."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        current = [i]
        for j, hyp in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (ref != hyp)))
        previous = current
    return previous[-1]


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def score(manifest_path, run_dir, include_preserved=False, numeric=False):
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    metadata = json.loads((run_dir / "run.json").read_text())
    if hashlib.sha256(manifest_bytes).hexdigest() != metadata["manifest_sha256"]:
        raise ValueError("Run and manifest checksum mismatch")
    if metadata["mode"] != "live":
        raise ValueError("Synthetic self-tests are not dataset results")
    samples = {s["sample_id"]: s for s in manifest["samples"]}
    preserved = metadata.get("preserved_successes", {}) if include_preserved else {}
    planned = metadata["planned_ids"] + list(preserved)
    if len(set(planned)) != len(planned) or any(s not in samples for s in planned):
        raise ValueError("Invalid run sample IDs")
    deadlines = [0, 250, 500, 1000, metadata["tail_ms"]]
    totals = {str(d): 0 for d in deadlines}
    denominator = 0
    first_text = []
    statuses = Counter()
    per_clip = []
    max_late = []
    for sample_id in planned:
        sample = samples[sample_id]
        path = Path(preserved[sample_id]["path"]) if sample_id in preserved else run_dir / (sample_id + ".json")
        if sample_id in preserved and hashlib.sha256(path.read_bytes()).hexdigest() != preserved[sample_id]["sha256"]:
            raise ValueError("Preserved result checksum mismatch")
        result = json.loads(path.read_text()) if path.exists() else {"status": "not_attempted"}
        if path.exists() and (result.get("sample_id") != sample_id or result.get("mode", "live") != "live"):
            raise ValueError("Invalid clip identity/mode")
        statuses[result["status"]] += 1
        if path.exists() and not result.get("close", {}).get("cleaned_up"):
            statuses["cleanup_unconfirmed"] += 1
        if path.exists() and not result.get("close", {}).get("finalized"):
            statuses["provider_finalization_unconfirmed"] += 1
        reference = words(sample["reference"])
        denominator += len(reference)
        events = result.get("events", [])
        if any(not isinstance(e["at_ms"], (int, float)) or e["at_ms"] < 0 for e in events):
            raise ValueError("Transcript event before clip start or invalid timestamp")
        events = sorted(events, key=lambda e: e["at_ms"])
        nonempty = [e for e in events if e["delta"].strip() and
                    e["at_ms"] <= sample["duration_ms"] + metadata["tail_ms"]]
        if nonempty:
            first_text.append(nonempty[0]["at_ms"])
        else:
            statuses["missing_transcript"] += 1
        if result.get("pacing"):
            max_late.append(result["pacing"]["max_late_ms"])
        clip = {"sample_id": sample_id, "status": result["status"], "reference": sample["reference"],
                "reference_words": len(reference), "errors_by_deadline_ms": {}, "pilot": sample["pilot"]}
        for deadline in deadlines:
            hypothesis = "".join(e["delta"] for e in events if e["at_ms"] <= sample["duration_ms"] + deadline)
            count = errors(reference, words(hypothesis))
            totals[str(deadline)] += count
            clip["errors_by_deadline_ms"][str(deadline)] = count
        clip["observed_transcript"] = hypothesis
        clip["wer"] = count / len(reference)
        if numeric:
            clip["numeric_meaning"] = numeric_compare(sample["reference"], hypothesis, errors)
        per_clip.append(clip)
    completion_path = run_dir / "completion.json"
    completion = json.loads(completion_path.read_text()) if completion_path.exists() else {}
    infrastructure_ok = (statuses["ok"] == len(planned) and completion.get("status") == "ok"
                         and completion.get("active_sessions") == 0
                         and statuses["cleanup_unconfirmed"] == 0
                         and statuses["provider_finalization_unconfirmed"] == 0
                         and len(max_late) == len(planned) and max(max_late, default=math.inf) <= 100)
    # Sanity threshold, not a product-quality SLO or statistical acceptance claim.
    tail_wer = totals[str(metadata["tail_ms"])] / denominator
    summary = {"schema_version": 1, "planned": len(planned), "status_counts": dict(statuses),
               "cohort": "recovered coverage" if preserved else "this run only",
               "preserved_prior_successes": len(preserved),
               "prior_runs": metadata.get("prior_runs", []),
               "scorer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "dataset": metadata["dataset"], "revision": metadata["dataset_revision"],
               "reference_words": denominator,
               "pooled_wer_by_clip_end_deadline_ms": {d: n / denominator for d, n in totals.items()},
               "first_text_from_clip_start_ms": {"p50": percentile(first_text, .5), "p95": percentile(first_text, .95)},
               "max_injection_lateness_ms": max(max_late, default=None),
               "infrastructure_ok": infrastructure_ok,
               "transcript_coverage_complete": statuses["missing_transcript"] == 0,
               "pilot_sanity_gate": infrastructure_ok and statuses["missing_transcript"] == 0 and tail_wer <= .25,
               "gate_note": "20-clip pilot: all attempts usable, no missing transcripts or remaining sessions, max injection lateness <=100 ms, pooled WER <=25%. Not production certification.",
               "normalization": "NFKC, lowercase, punctuation tokenization; apostrophes and digits preserved. No semantic/number normalization.",
               "limitations": ["Clip end is not an annotated speech endpoint.", "Captions are observed by a deadline, not declared final.",
                               "No browser/phone transport, audible response, or task-success scoring.",
                               "All planned clips stay in the denominator, including failed/unattempted clips."]}
    if numeric:
        assessments = [c["numeric_meaning"] for c in per_clip]
        relevant = [a for a in assessments if a["reference_entities"] or a["hypothesis_entities"]]
        resolved = [a for a in relevant if not a["review_required"]]
        ref_count = sum(a["reference_entity_count"] for a in resolved)
        edit_count = sum(a["errors"] for a in resolved)
        summary["numeric_meaning"] = {
            "version": NUMERIC_VERSION,
            "implementation_sha256": hashlib.sha256(Path(__file__).with_name("numeric_score.py").read_bytes()).hexdigest(),
            "deadline_ms_after_clip_end": metadata["tail_ms"],
            "clips_with_detected_entities": len(relevant),
            "clips_requiring_review": sum(a["review_required"] for a in assessments),
            "review_required_clips_with_detected_entities": sum(a["review_required"] for a in relevant),
            "automatically_scored_clips": len(resolved),
            "reference_entities_in_automatic_score": ref_count,
            "entity_edits_in_automatic_score": edit_count,
            "automatic_entity_error_rate": edit_count / ref_count if ref_count else None,
            "automatic_exact_match_clips": sum(a["exact_match"] for a in resolved),
            "limitations": ["Conservative English formatting rules, not general semantic understanding.",
                            "Review-required clips are excluded from the automatic metric and retained in the report.",
                            "Entities are compared in order, including units and identifier digits; surrounding intent is not scored.",
                            "No unit conversion or inferred date order. No effect on strict WER or the pilot gate."]}
    report_name = ("score-numeric-recovered.json" if include_preserved else "score-numeric.json") if numeric else ("score-recovered.json" if include_preserved else "score.json")
    (run_dir / report_name).write_text(json.dumps({"summary": summary, "clips": per_clip}, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("run", type=Path)
    parser.add_argument("--include-preserved", action="store_true",
                        help="Include verified prior successes; label as recovered coverage, not first-pass success")
    parser.add_argument("--numeric", action="store_true",
                        help="Write a separate report with strict WER plus conservative numeric-entity scoring")
    args = parser.parse_args()
    score(args.manifest, args.run, args.include_preserved, args.numeric)
