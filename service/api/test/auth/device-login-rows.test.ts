// The users and namespaces rows the TypeScript device login writes for a GitHub account at a given time on empty tables are the
// rows in service/lambda/fn_web_login/tests/fixtures/device_login_rows.json, which the Rust web login's tests hold its own sign-in to.
// Both languages create and read one `users` and one `namespaces` table.
import * as fs from "node:fs";
import * as path from "node:path";
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import { marshall } from "@aws-sdk/util-dynamodb";
import {
  authTablesFor,
  DynamoAuthStore,
} from "../../src/auth/dynamo-auth-store";
import { DynamoNamespaceStore } from "../../src/auth/dynamo-namespace-store";
import { DeviceLogin } from "../../src/auth/device-login";
import type { GitHubApi } from "../../src/auth/github";

const FIXTURE = path.join(
  __dirname,
  "../../../lambda/fn_web_login/tests/fixtures/device_login_rows.json",
);
const DOC = JSON.parse(fs.readFileSync(FIXTURE, "utf8")) as {
  github_user: {
    id: number;
    login: string;
    two_factor_authentication: boolean;
  };
  now: string;
  users: Record<string, unknown>[];
  namespaces: Record<string, unknown>[];
};

const KEYS: Record<string, string> = {
  users: "github_id",
  tokens: "token_hash",
  device_logins: "id",
  namespaces: "namespace",
};

/** An in-memory document client over empty tables: Get and Put keep rows by key, Update and Delete are accepted, every command is recorded. */
class Recording {
  sent: unknown[] = [];
  private readonly rows = new Map<string, Record<string, unknown>>();
  async send(command: unknown) {
    this.sent.push(command);
    if (command instanceof PutCommand) {
      const { TableName, Item } = command.input;
      const table = TableName!.replace(/^mopm-t-/, "");
      this.rows.set(`${table}/${String(Item![KEYS[table]])}`, Item!);
      return {};
    }
    if (command instanceof GetCommand) {
      const table = command.input.TableName!.replace(/^mopm-t-/, "");
      const item = this.rows.get(
        `${table}/${String(command.input.Key![KEYS[table]])}`,
      );
      return item ? { Item: item } : {};
    }
    if (command instanceof UpdateCommand || command instanceof DeleteCommand)
      return {};
    throw new Error(
      `unexpected command ${(command as object).constructor.name}`,
    );
  }
  puts(table: string): PutCommand[] {
    return this.sent.filter(
      (c): c is PutCommand =>
        c instanceof PutCommand && c.input.TableName === `mopm-t-${table}`,
    );
  }
}

/** GitHub approves the device flow at once and shows the fixture's account. */
const github: GitHubApi = {
  startDeviceFlow: async () => ({
    device_code: "gh-device-code",
    user_code: "ABCD-1234",
    verification_uri: "https://github.com/login/device",
    expires_in: 900,
    interval: 5,
  }),
  pollDeviceFlow: async () => ({ kind: "ok", access_token: "gh-access-token" }),
  getUser: async () => ({
    id: DOC.github_user.id,
    login: DOC.github_user.login,
    two_factor: DOC.github_user.two_factor_authentication,
  }),
  getOrgMembership: async () => null,
};

test("a device login of the golden account on empty tables writes exactly the golden users and namespaces rows", async () => {
  const doc = new Recording();
  const tables = {
    ...authTablesFor("t"),
    namespaces: "mopm-t-namespaces",
    namespace_members: "mopm-t-namespace_members",
  };
  const login = new DeviceLogin({
    store: new DynamoAuthStore(doc, tables),
    namespaces: new DynamoNamespaceStore(
      doc,
      tables.namespaces,
      tables.namespace_members,
    ),
    github,
    require2fa: true,
    now: () => new Date(DOC.now),
  });

  const started = await login.start({ client: "mopm" });
  const polled = await login.poll({ device_code: started.device_code });
  expect(polled.status).toBe("approved");

  const users = doc.puts("users");
  expect(users).toHaveLength(1);
  expect(marshall(users[0].input.Item as Record<string, unknown>)).toEqual(
    DOC.users[0],
  );
  expect(DOC.users).toHaveLength(1);

  const namespaces = doc.puts("namespaces");
  expect(namespaces).toHaveLength(1);
  expect(marshall(namespaces[0].input.Item as Record<string, unknown>)).toEqual(
    DOC.namespaces[0],
  );
  expect(DOC.namespaces).toHaveLength(1);
});
