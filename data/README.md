# EduCompass data package

`raw/combined_courses.csv` is the canonical source catalogue.

`processed/educompass_courses.csv` is the training catalogue used by the new
pipeline. It contains these 21 fields:

course_id, course_name, description, skills, subject, level, organization,
provider, rating, reviews_count, students_enrolled, lectures_count, duration,
instructor, price, language, image_url, url, certificate_type, course_type,
source_file.

It has 24,645 unique course IDs. `provider` and `organization` are normalized to
`EduCompass` for the app-facing catalogue. Original provider / organization /
source information is retained in `processed/course_source_map.csv`.

Missing image URLs and course URLs were not fabricated. The V4 deployment
trainer uses a strict valid-image + valid-URL rule before vectorization.
