// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@Test func filtersEnglishStopWordsAndSlideFurnitureOnMultiPageSlides() async {
    let slides = [
        """
        LECTURE 1: SLIDE OVERVIEW AND SUMMARY TODAY
        The Turing Machine formalises computation. This model follows Chomsky.
        However, Bayesian Inference handles uncertainty. Therefore, RNA and CRISPR matter.
        Although DNA and K-Means cluster patterns, NATO coordinates standards.
        Not Chomsky alone, and Topic Turing appears in Review Bayesian Inference.
        Between sessions, review the chapter. During seminars, compare results.
        Lecture 1, Slide 1, Chapter 1, Summary, Overview, References, University of Oxford.
        """,
        """
        CHAPTER 2: UNIVERSITY REFERENCES NEXT STEPS MUST WORK HERE
        The hierarchy proposed by Chomsky complements the Turing Machine.
        This step applies Bayesian Inference to CRISPR and RNA data.
        These readings use DNA and K-Means protocols approved with NATO partners.
        However, the bound holds. Therefore, convergence follows.
        Although noise remains, the signal is clear.
        Between trials, calibrate the scanner. During testing, record latencies.
        These conclusions close Lecture 2, Slide 2, Chapter 2, Summary, Overview, References, University.
        """,
    ]

    let terms = await Terms.candidates(in: slides)

    for kept in [
        "Chomsky", "Turing Machine", "Bayesian Inference", "CRISPR", "DNA", "RNA", "NATO",
        "K-Means",
    ] {
        #expect(terms.contains(kept))
    }
    for stopWord in [
        "The", "This", "These", "However", "Therefore", "Although", "Between", "During",
        "Not", "Topic", "Review", "Lecture", "Slide", "Chapter", "Summary", "Overview",
        "References", "University", "LECTURE", "SLIDE", "CHAPTER", "SUMMARY", "OVERVIEW",
        "REFERENCES", "UNIVERSITY", "TODAY", "NEXT", "MUST", "HERE",
        "The Turing Machine", "Not Chomsky", "Topic Turing", "Review Bayesian Inference",
    ] {
        #expect(!terms.contains(stopWord))
    }
}

@Test func keepsTermsAndFiltersStopWordsInBilingualCourseMaterial() async {
    let slides = [
        """
        COURS ET SLIDE 1: OVERVIEW
        Cependant, Chomsky et Jean Piaget sont cités à Aix-en-Provence. The Turing Machine est présentée.
        However, Bayesian Inference et CRISPR complètent l'analyse de l'RNA et du DNA.
        During the seminar, Robert May et NATO sont mentionnés.
        """,
        """
        CHAPITRE 2: SUMMARY AND REFERENCES
        Toutefois, Chomsky et Jean Piaget reviennent à Aix-en-Provence. This section covers Bayesian Inference.
        Therefore, the Turing Machine, CRISPR, DNA, RNA, and NATO remain central.
        Between lectures, relire Robert May.
        """,
    ]

    let terms = await Terms.candidates(in: slides)

    for kept in [
        "Chomsky", "Jean Piaget", "Aix-en-Provence", "Turing Machine", "Bayesian Inference",
        "CRISPR", "DNA", "RNA", "NATO", "Robert May",
    ] {
        #expect(terms.contains(kept))
    }
    for excluded in [
        "Cependant", "Toutefois", "The", "This", "However", "Therefore", "During", "Between",
        "COURS", "SLIDE", "OVERVIEW", "CHAPITRE", "SUMMARY", "REFERENCES",
    ] {
        #expect(!terms.contains(excluded))
    }
}
