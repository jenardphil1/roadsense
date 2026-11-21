# Script to generate thesis deliverables
import os
import sys

def build_all():
    import tools.generate_report as gr
    import tools.generate_revised as gv
    gr.generate_report()
    gv.generate_revised()
    print("All deliverables generated successfully!")

if __name__ == "__main__":
    build_all()
