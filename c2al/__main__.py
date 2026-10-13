# python -m c2al <project/c2al.json> [--out <file.al>] [--unchecked]
import argparse
from .driver import build_project


def main():
    ap = argparse.ArgumentParser(prog='c2al', description='Translate a C program to a Business Central AL codeunit.')
    ap.add_argument('project', help='path to a c2al.json project file')
    ap.add_argument('--out', help='write the AL codeunit here instead of the project\'s out_al')
    ap.add_argument('--unchecked', action='store_true', help='JS build without overflow checks (faster)')
    a = ap.parse_args()
    build_project(a.project, a.out, checked=not a.unchecked)


if __name__ == '__main__':
    main()
