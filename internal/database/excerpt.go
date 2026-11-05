package database

import (
	"encoding/json"
	"html"
	"regexp"
	"strings"
	"unicode"
)

var (
	excerptFence      = regexp.MustCompile("(?m)^\\s*(?:`{3,}|~{3,}).*$")
	excerptRule       = regexp.MustCompile(`(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$`)
	excerptTableRule  = regexp.MustCompile(`(?m)^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$`)
	excerptStrong     = regexp.MustCompile(`\*{1,2}([^*\n]+)\*{1,2}`)
	excerptUnderscore = regexp.MustCompile(`(^|[^\pL\pN_])_{1,2}([^_\n]+)_{1,2}($|[^\pL\pN_])`)
	excerptCode       = regexp.MustCompile("`+([^`\\n]+)`+")

	excerptCitationLink     = regexp.MustCompile(`\[\d+\]\([^)]*\)`)
	excerptCitation         = regexp.MustCompile(`(?i)\[\[?\^?\d+(?:[, -]+\d+)*\]?\]|\[\^[^\]]+\]|\[(?:S\d+|source[^\]]*|segment[^\]]*|[0-9a-f]{8}-[0-9a-f-]{27,})\]|【[^】]*】|<cite\b[^>]*>.*?</cite>|\[citation[^\]]*\]`)
	excerptLink             = regexp.MustCompile(`!?\[([^\]]*)\]\([^)]*\)`)
	excerptHTML             = regexp.MustCompile(`</?[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[^<>]*)?/?>`)
	excerptPunctuationSpace = regexp.MustCompile(`\s+([.,;:!?])`)
	excerptLinePrefix       = regexp.MustCompile(`(?m)^\s*(?:#{1,6}\s+|>\s*|[-+*]\s+|\d{1,3}[.)]\s+)`)
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
				// SQL can stop inside a JSON escape (including \uXXXX). Remove
				// only the incomplete tail; retain the usable summary instead of
				// discarding it in favor of the transcript. UTF-8/escape tails fit
				// within twelve bytes; do not repeatedly decode the entire prefix.
				decoded := false
				for trim := 0; trim <= 12 && len(source)-trim >= 1; trim++ {
					if json.Unmarshal([]byte(source[:len(source)-trim]+`"`), &text) == nil {
						source = text
						decoded = true
						break
					}
				}
				if !decoded {
					return ""
				}
			}
		}
	}
	source = excerptFence.ReplaceAllString(source, " ")
	source = excerptRule.ReplaceAllString(source, " ")
	source = excerptTableRule.ReplaceAllString(source, " ")
	source = excerptCitationLink.ReplaceAllString(source, "")
	source = excerptLink.ReplaceAllString(source, "$1")
	source = excerptCitation.ReplaceAllString(source, "")
	source = excerptHTML.ReplaceAllString(source, " ")
	source = excerptLinePrefix.ReplaceAllString(source, "")
	source = excerptStrong.ReplaceAllString(source, "$1")
	source = excerptUnderscore.ReplaceAllString(source, "$1$2$3")
	source = excerptCode.ReplaceAllString(source, "$1")
	source = strings.ReplaceAll(source, "~~", "")
	source = strings.ReplaceAll(source, "|", " ")
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
		end = 200 // CJK and other unspaced text still get a rune-safe excerpt.
	}
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
