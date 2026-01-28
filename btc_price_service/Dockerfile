# Use the official Python image with a slim OS footprint.
FROM python:3.11-slim

# Set working directory inside the container
WORKDIR /app

# Install application dependencies
COPY requirements.txt .
# Install dependencies without caching to reduce image size
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code
COPY app.py .

# Expose the port that the Flask app listens on
EXPOSE 8000

# Run the application
CMD ["python", "app.py"]