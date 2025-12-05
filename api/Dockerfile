# Use a lightweight Python image
FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Install system dependencies in a single RUN layer, clean up to reduce image size
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql-client \
        libpq-dev \
        gcc \
        python3-dev \
        bash \
        dos2unix \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first to leverage Docker layer caching
COPY requirements.txt .

# Upgrade pip and install Python dependencies
RUN pip install --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Convert scripts to Unix format and make executable
RUN if [ -f migrate.sh ]; then dos2unix migrate.sh && chmod +x migrate.sh; fi

# Expose application port
EXPOSE 8000

# Use a more secure default user instead of root
RUN useradd --create-home appuser
USER appuser

# Set entrypoint / default command
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "run:app"]
