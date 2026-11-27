FROM python:3.13.18-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as an unprivileged user; the app only needs to bind port 5000. The home directory
# is required: gunicorn writes its control socket there and logs an error without one.
RUN useradd --system --uid 10001 --create-home app
USER 10001

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
