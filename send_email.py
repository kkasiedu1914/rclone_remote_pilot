#!/usr/bin/env python3
import argparse, os, smtplib
from email.message import EmailMessage

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--to", action="append", required=True, help="Recipient (repeatable)")
    p.add_argument("--subject", required=True)
    p.add_argument("--body", required=True)
    args = p.parse_args()

    user = os.environ["SMTP_USER"]
    pw   = os.environ["SMTP_PASS"]

    msg = EmailMessage()
    msg["From"] = user
    msg["To"] = ", ".join(args.to)
    msg["Subject"] = args.subject
    msg.set_content(args.body)

    # Use STARTTLS on 587 (recommended)
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as s:
        s.ehlo()
        s.starttls()
        s.ehlo()
        s.login(user, pw)
        s.send_message(msg)

if __name__ == "__main__":
    main()
