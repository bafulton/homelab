"""Validate repository metadata consumed by the Argo CD ApplicationSets."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
SYNC_OPTIONS = {"serverSideApply", "prune", "selfHeal"}


def main() -> None:
    errors = []
    for area in ("infra", "apps"):
        for path in sorted((ROOT / "kubernetes" / area).glob("*/values.yaml")):
            values = yaml.safe_load(path.read_text())
            if not isinstance(values, dict):
                errors.append(f"{path.relative_to(ROOT)}: values must be a mapping")
                continue
            if "serverSideApply" in values:
                errors.append(
                    f"{path.relative_to(ROOT)}: put serverSideApply under syncPolicy"
                )
            policy = values.get("syncPolicy", {})
            if not isinstance(policy, dict):
                errors.append(f"{path.relative_to(ROOT)}: syncPolicy must be a mapping")
                continue
            for key, value in policy.items():
                if key not in SYNC_OPTIONS:
                    errors.append(
                        f"{path.relative_to(ROOT)}: syncPolicy.{key} is not read by the ApplicationSets"
                    )
                elif not isinstance(value, bool):
                    errors.append(
                        f"{path.relative_to(ROOT)}: syncPolicy.{key} must be a boolean"
                    )
    if errors:
        raise SystemExit("\n".join(errors))


if __name__ == "__main__":
    main()
