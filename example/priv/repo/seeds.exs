# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Example.Repo.insert!(%Example.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Example.Accounts.User
alias Example.Library.Author

Ash.create!(User, %{name: "Ada", email: "ada@example.test"}, authorize?: false)
Ash.create!(User, %{name: "Grace", email: "grace@example.test"}, authorize?: false)

Ash.create!(Author, %{name: "Ursula", email: "ursula@example.test"}, authorize?: false)
Ash.create!(Author, %{name: "Octavia", email: "octavia@example.test"}, authorize?: false)
