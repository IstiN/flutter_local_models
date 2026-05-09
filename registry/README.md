# Model registry

Each file in `registry/models` is the source-of-truth manifest for one bundled model.

The intended flow is:

1. define a model manifest here
2. run `release-model.yml` for that manifest
3. the workflow downloads from Hugging Face, packages the model, splits it into release-safe parts, and uploads one GitHub Release per model
4. clients consume the resulting GitHub Release metadata instead of talking directly to Hugging Face
