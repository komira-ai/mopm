# The transitive case: this program imports only outer. inner is installed
# only as outer's dependency (outer's metadata lists it in deps and libouter
# needs libinner), and nothing here names inner or libinner.
from outer import chain


def main():
    print("chain", chain())
