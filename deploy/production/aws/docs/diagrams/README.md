# Architecture diagrams

`aws-light-architecture.png` and `aws-architecture.png` are generated from
`aws-light.py` and `aws.py`. Regenerate them after a change to either stack's
Terraform. Do not edit the image files by hand. Both use the official AWS
Architecture Icons through the [`diagrams`](https://diagrams.mingrammer.com/)
Python library.

## Regenerating

```bash
brew install graphviz          # diagrams runs `dot` for the layout
python3 -m venv .venv && source .venv/bin/activate
pip install diagrams
python aws-light.py            # writes aws-light-architecture.png
python aws.py                  # writes aws-architecture.png
```

Move the two files here, overwriting the existing ones, and commit them with
the `.py` source that produced them. Run `make check-public` before the
commit: it also scans binary files.
