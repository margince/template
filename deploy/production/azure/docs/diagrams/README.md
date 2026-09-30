# Architecture diagrams

`azure-light-architecture.png` and `azure-architecture.png` are generated
from `azure-light.py` and `azure.py`. Regenerate them after a change to
either stack's Terraform. Do not edit the image files by hand. Both use the
official Azure icons through the
[`diagrams`](https://diagrams.mingrammer.com/) Python library.

## Regenerating

```bash
brew install graphviz          # diagrams runs `dot` for the layout
python3 -m venv .venv && source .venv/bin/activate
pip install diagrams
python azure-light.py          # writes azure-light-architecture.png
python azure.py                # writes azure-architecture.png
```

Move the two files here, overwriting the existing ones, and commit them with
the `.py` source that produced them. Run `make check-public` before the
commit: it also scans binary files.
