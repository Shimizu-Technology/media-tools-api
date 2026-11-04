package database

import (
	"encoding/json"
	"html"
	"regexp"
	"strings"
	"unicode"
)

var (
	excerptCitationLink     = regexp.MustCompile(`\[\d+\]\([^)]*\)`)
	excerptCitation         = regexp.MustCompile(`(?i)\[\[?\^?\d+(?:[, -]+\d+)*\]?\]|\[\^[^\]]+\]|\[(?:S\d+|source[^\]]*|segment[^\]]*|[0-9a-f]{8}-[0-9a-f-]{27,})\]|【[^】]*】|<cite\b[^>]*>.*?</cite>|\[citation[^\]]*\]`)
	excerptLink             = regexp.MustCompile(`!?\[([^\]]*)\]\([^)]*\)`)
	excerptHTML             = regexp.MustCompile(`<[^>]*>`)
	excerptPunctuationSpace = regexp.MustCompile(`\s+([.,;:!?])`)
	excerptLinePrefix       = regexp.MustCompile(`(?m)^\s*(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)`)
	excerptJSONField        = regexp.MustCompile(`"(?:summary|summary_text|text)"\s*:\s*"`)
)

// plainExcerpt sees at most 4096 source characters from SQL. Structured legacy
// summaries prefer their human text, including a bounded/truncated JSON prefix.
func plainExcerpt(source string) string {
	source = strings.TrimSpace(source)
	if strings.HasPrefix(source, "{") || strings.HasPrefix(source, "[") || strings.HasPrefix(source, `"`) {
		var value any
		if json.Unmarshal([]byte(source), &value) == nil {
			source = summaryPlainText(value)
		} else if strings.HasPrefix(source, "{") {
			loc := excerptJSONField.FindStringIndex(source)
			if loc == nil {
				return ""
			}
			source = source[loc[1]-1:]
			var text string
			decoder := json.NewDecoder(strings.NewReader(source))
			if decoder.Decode(&text) == nil {
				source = text
			} else {
				// A long JSON string can be cut inside an escape; trim its incomplete
				// tail until it can be decoded. The bounded input caps this work.
				source = strings.TrimSuffix(source, `\`)
				if json.Unmarshal([]byte(source+`"`), &text) == nil {
					source = text
				} else {
					return ""
				}
			}
		}
	}
	source = excerptCitationLink.ReplaceAllString(source, "")
	source = excerptLink.ReplaceAllString(source, "$1")
	source = excerptCitation.ReplaceAllString(source, "")
	source = excerptHTML.ReplaceAllString(source, " ")
	source = excerptLinePrefix.ReplaceAllString(source, "")
	source = strings.NewReplacer("*", "", "_", "", "`", "", "~~", "").Replace(source)
	source = strings.Join(strings.Fields(html.UnescapeString(source)), " ")
	source = excerptPunctuationSpace.ReplaceAllString(source, "$1")
	runes := []rune(source)
	if len(runes) <= 200 {
		return source
	}
	end := 200
	for end > 0 && !unicode.IsSpace(runes[end]) {
		end--
	}
	if end == 0 {
		return ""
	} // no complete word fits (for example a giant URL)
	return strings.TrimSpace(string(runes[:end]))
}

func summaryPlainText(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case map[string]any:
		for _, key := range []string{"summary", "summary_text", "text"} {
			if text := summaryPlainText(v[key]); text != "" {
				return text
			}
		}
	case []any:
		parts := make([]string, 0, len(v))
		for _, item := range v {
			if text := summaryPlainText(item); text != "" {
				parts = append(parts, text)
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}
