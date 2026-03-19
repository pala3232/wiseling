FROM python:3.12-slim

WORKDIR /locust

RUN pip install locust==2.31.0

COPY locustfile.py .

ENTRYPOINT ["locust", "-f", "locustfile.py"]
