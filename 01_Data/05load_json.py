import json
import psycopg2


# ============================================================
# SWIFT Assignment 7
# File: 05load_json.py
# Purpose: Load newline-delimited JSON data into PostgreSQL
# ============================================================

print("Starting JSON loader...")


# ============================================================
# STEP 1: Connect to PostgreSQL
# ============================================================

conn = psycopg2.connect(
    host="localhost",
    port=5432,
    database="swift_assignment7",
    user="postgres",
    password=input("Enter PostgreSQL password: ")
)

cursor = conn.cursor()


# ============================================================
# STEP 2: Open the NDJSON dataset
# ============================================================
#
# The dataset contains one JSON object per line.
# ============================================================

file_path = "SWIFT Assignment 7 - Analyst - CH.json"

print("Opening JSON file...")


# ============================================================
# STEP 3: Read and insert each shipment
# ============================================================

with open(
    file_path,
    "r",
    encoding="utf-8"
) as file:

    count = 0

    for line in file:

        line = line.strip()

        # Skip empty lines
        if not line:
            continue

        # Convert the JSON text into a Python object
        data = json.loads(line)

        # Insert the JSON record into PostgreSQL
        cursor.execute(
            """
            INSERT INTO swift.raw_shipments (data)
            VALUES (%s)
            """,
            (json.dumps(data),)
        )

        count += 1


# ============================================================
# STEP 4: Save the transaction
# ============================================================

conn.commit()


# ============================================================
# STEP 5: Close database resources
# ============================================================

cursor.close()
conn.close()


# ============================================================
# STEP 6: Display loading result
# ============================================================

print(
    f"Successfully loaded {count} shipments."
)