//go:build ruleguard

// Package gorules holds project-specific lint rules, run by gocritic's ruleguard check (.golangci.yml).
// Guardrail (protected): rules here encode ADRs that the stock linters cannot express.
package gorules

import "github.com/quasilyte/go-ruleguard/dsl"

// sqlFromStrings flags SQL assembled from values. gosec only recognises database/sql, so this also covers
// pgx and any other client with Exec/Query/QueryRow methods (OWASP A03, docs/adr/0003-datastores.md).
func sqlFromStrings(m dsl.Matcher) {
	m.Match(
		`$db.$method($ctx, $left + $right, $*_)`,
		`$db.$method($ctx, fmt.Sprintf($*_), $*_)`,
		`$db.$method($left + $right, $*_)`,
		`$db.$method(fmt.Sprintf($*_), $*_)`,
	).
		Where(m["method"].Text.Matches(`^(Exec|Query|QueryRow)(Context)?$`)).
		Report(`Do not build SQL from strings. Use placeholders ($1, $2 ...) and pass values as arguments (docs/adr/0003-datastores.md).`)
}
