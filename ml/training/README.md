# EduCompass recommender training

The current production model is **V4 hybrid-ready TF-IDF**. It keeps the
existing content-based recommender and adds preference / behavior reranking in
the Flask backend; no second ML model is required.

## Rebuild

Run from the repository root:

```bash
python ml/training/prepare_educompass_dataset.py
python ml/training/train_v4_15k.py
```

The first command converts `data/raw/combined_courses.csv` into the canonical
21-column `data/processed/educompass_courses.csv`. App-facing `provider` and
`organization` are both `EduCompass`, while the original source values are
preserved in `data/processed/course_source_map.csv`.

The trainer keeps only courses with both a valid course URL and image URL,
deduplicates them, creates weighted deployment text, and writes:

- `ml/artifacts/models/v4/courses.csv.gz`
- `ml/artifacts/models/v4/tfidf_vectorizer.joblib`
- `ml/artifacts/models/v4/tfidf_matrix.npz`
- `ml/artifacts/models/v4/model_config.json`
- `ml/artifacts/models/v4/model_metadata.json`

Current rebuilt bundle: 3,124 courses × 20,000 TF-IDF features.
